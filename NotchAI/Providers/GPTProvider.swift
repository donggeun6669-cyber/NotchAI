import Foundation
import Observation

/// Codex (GPT). Watches its session logs, and runs `codex exec` for commands sent from the notch.
/// Uses the local Codex login (ChatGPT account); no OpenAI API key.
@MainActor
@Observable
final class GPTProvider: AIProvider {
    let kind = ProviderKind.gpt
    let status = AgentStatus()
    private(set) var availability: ProviderAvailability = .checking
    private(set) var isRunningCommand = false

    private var chosenDirectory: URL?
    private var sessionDirectory: URL?
    var workingDirectory: URL? {
        get { chosenDirectory ?? sessionDirectory }
        set { chosenDirectory = newValue }
    }

    @ObservationIgnored private let monitor = CodexMonitor()
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var process: StreamingProcess?
    @ObservationIgnored private var lastMessage: String?

    func start() {
        monitor.onEvent = { [weak self] event, date in
            guard let self, !self.isRunningCommand else { return }
            self.status.handle(event, at: date)
        }
        Task { await checkAvailability() }
    }

    func poll() {
        monitor.poll()
        if sessionDirectory != monitor.sessionDirectory { sessionDirectory = monitor.sessionDirectory }
        if !isRunningCommand { status.expireIfStale(after: CodexMonitor.staleAfter) }
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

    func sendPrompt(_ prompt: String) {
        guard !isRunningCommand else { return }
        Task {
            if availability != .ready { await checkAvailability() }
            guard availability == .ready, let executable else {
                status.handle(.failed(availability.message ?? "Codex unavailable"))
                return
            }
            let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let shell = await ProcessService.shell.value
            // workspace-write: Codex may edit files inside the chosen folder only.
            let process = StreamingProcess(
                executable: executable,
                arguments: ["exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write",
                            "-C", directory.path, prompt],
                directory: directory,
                environment: ProcessService.agentEnvironment(shell: shell))
            lastMessage = nil
            process.onLine = { [weak self] line in
                guard let self, let parsed = CodexExecParser.parse(line) else { return }
                if let message = parsed.message { self.lastMessage = message }
                guard let event = parsed.event else { return }
                self.status.handle(event == .completed(nil) ? .completed(self.lastMessage) : event)
            }
            process.onExit = { [weak self] code, errors in
                guard let self else { return }
                self.isRunningCommand = false
                self.process = nil
                guard self.status.state.isBusy else { return }
                if code == 0 {
                    self.status.handle(.completed(self.lastMessage))
                } else {
                    self.status.handle(.failed(ClaudeTranscriptParser.summary(errors.isEmpty ? "Exited with code \(code)" : errors)))
                }
            }
            status.handle(.promptSubmitted(ClaudeTranscriptParser.summary(prompt)))
            do {
                try process.start()
                self.process = process
                isRunningCommand = true
            } catch {
                status.handle(.failed(error.localizedDescription))
            }
        }
    }

    func cancelCommand() {
        process?.terminate()
        status.handle(.interrupted)
    }
}
