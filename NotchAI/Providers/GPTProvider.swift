import Foundation
import Observation

/// Codex (GPT). Watches its sessions, and talks through `codex exec` for the notch chat.
/// Uses the local Codex login (ChatGPT account); no OpenAI API key.
@MainActor
@Observable
final class GPTProvider: AIProvider {
    let kind = ProviderKind.gpt
    let status = AgentStatus()
    let chat = ChatSession()
    private(set) var availability: ProviderAvailability = .checking
    private(set) var isRunningCommand = false
    private(set) var overview = AgentOverview()
    private(set) var isRefreshingUsage = false

    private var chosenDirectory: URL?
    private var sessionDirectory: URL?
    var workingDirectory: URL? {
        get { chosenDirectory ?? sessionDirectory }
        set { chosenDirectory = newValue }
    }

    @ObservationIgnored private let monitor = CodexMonitor()
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var process: StreamingProcess?
    /// Held while a usage refresh runs; without it the process object (and its callbacks) went away.
    @ObservationIgnored private var refreshProcess: StreamingProcess?
    @ObservationIgnored private var lastMessage: String?
    @ObservationIgnored private var lastSessionsRefresh = Date.distantPast
    @ObservationIgnored private var lastUsageRefresh = Date.distantPast

    func start() {
        monitor.onEvent = { [weak self] event, date in
            guard let self, !self.isRunningCommand else { return }
            // Usage refreshes are not work the user started.
            if self.monitor.sessionDirectory?.standardizedFileURL == UsageRefresh.directory.standardizedFileURL { return }
            self.status.handle(event, at: date)
        }
        Task { await checkAvailability() }
    }

    func poll() {
        monitor.poll()
        // A usage refresh's folder is not where the user works.
        if let directory = monitor.sessionDirectory, directory != sessionDirectory,
           directory.standardizedFileURL != UsageRefresh.directory.standardizedFileURL {
            sessionDirectory = directory
        }
        if !isRunningCommand { status.expireIfStale(after: CodexMonitor.staleAfter) }
        refreshOverview()
    }

    private func refreshOverview() {
        var updated = overview
        if Date.now.timeIntervalSince(lastSessionsRefresh) >= 5 {
            lastSessionsRefresh = .now
            // The app's own state knows which threads are open and what they are called; the
            // logs are the fallback when that cannot be read.
            if let snapshot = CodexStateReader.read() {
                updated.sessions = snapshot.sessions
                updated.subagentsRunning = snapshot.subagentsRunning
            } else {
                updated.sessions = AgentOverviewReader.codexSessions()
                updated.subagentsRunning = 0
            }
        }
        // Usage is written with every Codex turn; reading the log tails every 30 s is plenty.
        if Date.now.timeIntervalSince(lastUsageRefresh) >= 30 {
            lastUsageRefresh = .now
            updated.usage = AgentOverviewReader.codexUsage() ?? updated.usage
        }
        if updated != overview { overview = updated }
    }

    func checkAvailability() async {
        let shell = await ProcessService.shell.value
        guard let codex = shell.executable(named: "codex") else {
            availability = .notInstalled
            return
        }
        executable = codex
        let output = (try? await ProcessService.run(codex, arguments: ["login", "status"],
                                                   environment: ProcessService.agentEnvironment(shell: shell))) ?? ""
        availability = output.contains("Logged in")
            ? .ready
            : .needsLogin("Codex 로그인 필요 — 터미널에서 codex login")
    }

    /// Arguments for one chat turn. The first turn starts a thread in `directory` (edits allowed
    /// inside it only); later turns resume that thread.
    nonisolated static func arguments(prompt: String, directory: URL, threadID: String?) -> [String] {
        if let threadID {
            return ["exec", "resume", "--json", "--skip-git-repo-check",
                    "-c", "sandbox_mode=\"workspace-write\"", threadID, prompt]
        }
        return ["exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write",
                "-C", directory.path, prompt]
    }

    func sendPrompt(_ prompt: String) {
        guard !isRunningCommand else { return }
        chat.add(.user, prompt)
        Task { [weak self] in
            guard let self else { return }
            if availability != .ready { await checkAvailability() }
            guard availability == .ready, let executable else {
                let message = availability.message ?? "Codex unavailable"
                chat.add(.error, message)
                status.handle(.failed(message))
                return
            }
            let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let shell = await ProcessService.shell.value
            let process = StreamingProcess(
                executable: executable,
                arguments: Self.arguments(prompt: prompt, directory: directory, threadID: chat.conversationID),
                directory: directory,
                environment: ProcessService.agentEnvironment(shell: shell))
            lastMessage = nil
            process.onLine = { [weak self] line in
                guard let self else { return }
                ChatStreamParser.codex(line).forEach(self.chat.apply)
                guard let parsed = CodexExecParser.parse(line) else { return }
                if let message = parsed.message { self.lastMessage = message }
                guard let event = parsed.event else { return }
                self.status.handle(event == .completed(nil) ? .completed(self.lastMessage) : event)
            }
            process.onExit = { [weak self] code, errors in
                guard let self else { return }
                self.isRunningCommand = false
                self.process = nil
                self.lastUsageRefresh = .distantPast   // the turn just logged fresh usage
                guard self.status.state.isBusy else { return }
                if code == 0 {
                    self.status.handle(.completed(self.lastMessage))
                } else {
                    let message = ClaudeTranscriptParser.summary(errors.isEmpty ? "Exited with code \(code)" : errors)
                    self.chat.apply(.failed(message))
                    self.status.handle(.failed(message))
                }
            }
            status.handle(.promptSubmitted(ClaudeTranscriptParser.summary(prompt)))
            do {
                try process.start()
                self.process = process
                isRunningCommand = true
            } catch {
                chat.apply(.failed(error.localizedDescription))
                status.handle(.failed(error.localizedDescription))
            }
        }
    }

    func cancelCommand() {
        process?.terminate()
        chat.apply(.failed("멈춤"))
        status.handle(.interrupted)
    }

    func newChat() {
        guard !isRunningCommand else { return }
        chat.reset()
    }

    /// One short, low-effort turn in the refresh folder. Codex does not put usage in its JSON
    /// output, but logs it with every turn; the next overview refresh reads it from there.
    nonisolated static let usageRefreshArguments = [
        "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only",
        "-c", "model_reasoning_effort=\"low\"", "Reply with: ok",
    ]

    func refreshUsage() {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        Task { [weak self] in
            guard let self else { return }
            if availability != .ready { await checkAvailability() }
            guard availability == .ready, let executable else {
                isRefreshingUsage = false
                return
            }
            let shell = await ProcessService.shell.value
            let process = StreamingProcess(executable: executable, arguments: Self.usageRefreshArguments,
                                           directory: UsageRefresh.prepareDirectory(),
                                           environment: ProcessService.agentEnvironment(shell: shell))
            process.onExit = { [weak self] _, _ in
                guard let self else { return }
                self.isRefreshingUsage = false
                self.refreshProcess = nil
                self.lastUsageRefresh = .distantPast
                self.lastSessionsRefresh = .distantPast
                self.refreshOverview()
            }
            do {
                try process.start()
                refreshProcess = process
            } catch {
                isRefreshingUsage = false
            }
        }
    }
}
