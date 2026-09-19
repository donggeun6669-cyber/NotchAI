import Foundation
import Observation
import os

/// Claude Code. Watches its sessions, and talks through `claude -p` for the notch chat.
@MainActor
@Observable
final class ClaudeProvider: AIProvider {
    /// Which model notch messages use. Sonnet by default: the notch is for quick questions, and
    /// this keeps the subscription's usage window for the long sessions.
    enum Model: String, CaseIterable, Identifiable {
        case sonnet, opus, configured

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sonnet: "Sonnet (기본)"
            case .opus: "Opus"
            case .configured: "설정값 그대로"
            }
        }
        var flag: [String] { self == .configured ? [] : ["--model", rawValue] }
    }

    let kind = ProviderKind.claude
    let status = AgentStatus()
    let chat = ChatSession()
    private(set) var availability: ProviderAvailability = .checking
    private(set) var isRunningCommand = false
    private(set) var overview = AgentOverview()
    private(set) var isRefreshingUsage = false

    var model: Model = UserDefaults.standard.string(forKey: "claudeModel").flatMap(Model.init) ?? .sonnet {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "claudeModel") }
    }

    private var chosenDirectory: URL?
    private var sessionDirectory: URL?
    var workingDirectory: URL? {
        get { chosenDirectory ?? sessionDirectory }
        set { chosenDirectory = newValue }
    }

    @ObservationIgnored private let monitor = ClaudeCodeMonitor()
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var process: StreamingProcess?
    /// Held while a usage refresh runs; without it the process object (and its callbacks) went away.
    @ObservationIgnored private var refreshProcess: StreamingProcess?
    @ObservationIgnored private var lastOverviewRefresh = Date.distantPast

    /// Claude's usage only arrives with the notch's own requests, so the last reading is kept.
    private static let usageKey = "claudeUsage"
    @ObservationIgnored private var storedUsage: AgentOverview.Usage? = {
        guard let data = UserDefaults.standard.data(forKey: usageKey) else { return nil }
        return try? JSONDecoder().decode(AgentOverview.Usage.self, from: data)
    }()

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
        if !isRunningCommand { status.expireIfStale(after: ClaudeCodeMonitor.staleAfter) }
        refreshOverview()
    }

    private func refreshOverview() {
        guard Date.now.timeIntervalSince(lastOverviewRefresh) >= 3 else { return }
        lastOverviewRefresh = .now
        let sessions = AgentOverviewReader.claudeSessions()
        let subagents = AgentOverviewReader.claudeSubagentsRunning(sessionIDs: sessions.filter(\.isBusy).map(\.id))
        // The status line reading (every minute, from any Claude Code session) and the notch's own
        // chat replies both carry usage; show whichever is newer.
        if let fromStatusline = AgentOverviewReader.claudeUsageFromStatusline(),
           fromStatusline.observedAt > (storedUsage?.observedAt ?? .distantPast) {
            storedUsage = fromStatusline
        }
        let updated = AgentOverview(sessions: sessions, subagentsRunning: subagents, usage: storedUsage)
        if updated != overview { overview = updated }
    }

    private func store(_ usage: AgentOverview.Usage) {
        storedUsage = usage
        if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: Self.usageKey) }
        overview.usage = usage
    }

    func checkAvailability() async {
        let shell = await ProcessService.shell.value
        guard let claude = shell.executable(named: "claude") else {
            availability = .notInstalled
            return
        }
        executable = claude
        let output = (try? await ProcessService.run(claude, arguments: ["auth", "status"],
                                                   environment: ProcessService.agentEnvironment(shell: shell))) ?? ""
        availability = Self.availability(fromAuthStatus: output)
        Logger(subsystem: "com.dongeun.NotchAI", category: "provider")
            .info("claude availability: \(String(describing: self.availability), privacy: .public)")
    }

    /// Messages are only sent with a subscription login. An API-key / Console login bills per
    /// request, so it is refused (the user's rule: no paid API calls).
    nonisolated static func availability(fromAuthStatus output: String) -> ProviderAvailability {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              object["loggedIn"] as? Bool == true else {
            return .needsLogin("Claude CLI 로그인 필요 — 터미널에서 claude → /login (구독 계정)")
        }
        let method = (object["authMethod"] as? String ?? "").lowercased()
        let billing = (object["billingType"] as? String ?? "").lowercased()
        if method.isEmpty || method.contains("api") || method.contains("console") || method.contains("key")
            || billing.contains("api") || billing.contains("usage") {
            return .needsLogin("API 과금 로그인이라 보내기 막음 — 구독 계정으로 /login")
        }
        return .ready
    }

    /// Arguments for one chat turn; later turns resume the same conversation.
    nonisolated static func arguments(prompt: String, model: Model, conversationID: String?) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                         "--permission-mode", "acceptEdits"] + model.flag
        if let conversationID { arguments += ["--resume", conversationID] }
        return arguments
    }

    func sendPrompt(_ prompt: String) {
        guard !isRunningCommand else { return }
        chat.add(.user, prompt)
        Task { [weak self] in
            guard let self else { return }
            if availability != .ready { await checkAvailability() }
            guard availability == .ready, let executable else {
                let message = availability.message ?? "Claude Code unavailable"
                chat.add(.error, message)
                status.handle(.failed(message))
                return
            }
            let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let shell = await ProcessService.shell.value
            // Headless: file edits are allowed, other tools that need permission are refused
            // (there is nobody to answer the prompt).
            let process = StreamingProcess(
                executable: executable,
                arguments: Self.arguments(prompt: prompt, model: model, conversationID: chat.conversationID),
                directory: directory,
                environment: ProcessService.agentEnvironment(shell: shell))
            process.onLine = { [weak self] line in
                guard let self else { return }
                if let usage = AgentOverviewReader.claudeUsage(fromStreamLine: line) { self.store(usage) }
                ChatStreamParser.claude(line).forEach(self.chat.apply)
                guard let entry = ClaudeTranscriptParser.parse(line) else { return }
                if case .promptSubmitted = entry.event { return }
                self.status.handle(entry.event)
            }
            process.onExit = { [weak self] code, errors in
                guard let self else { return }
                self.isRunningCommand = false
                self.process = nil
                guard self.status.state.isBusy else { return }
                if code == 0 {
                    self.status.handle(.completed(nil))
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

    /// Haiku, a one-line system prompt, no tools, no MCP, nothing saved: about 2k tokens.
    /// The reply carries a rate_limit_event with the plan's current usage.
    nonisolated static let usageRefreshArguments = [
        "-p", "ok", "--output-format", "stream-json", "--verbose", "--model", "haiku",
        "--system-prompt", "Reply with: ok", "--tools", "", "--strict-mcp-config",
        "--no-session-persistence", "--disable-slash-commands",
    ]

    func refreshUsage() {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        Task { [weak self] in
            guard let self else { return }
            if availability != .ready { await checkAvailability() }
            // Same rule as chat: only on a subscription login.
            guard availability == .ready, let executable else {
                isRefreshingUsage = false
                return
            }
            let shell = await ProcessService.shell.value
            let process = StreamingProcess(executable: executable, arguments: Self.usageRefreshArguments,
                                           directory: UsageRefresh.prepareDirectory(),
                                           environment: ProcessService.agentEnvironment(shell: shell))
            process.onLine = { [weak self] line in
                if let usage = AgentOverviewReader.claudeUsage(fromStreamLine: line) { self?.store(usage) }
            }
            process.onExit = { [weak self] _, _ in
                self?.isRefreshingUsage = false
                self?.refreshProcess = nil
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
