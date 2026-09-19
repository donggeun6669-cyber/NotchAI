import Foundation
import Observation
import os

/// Claude Code. Watches its transcripts, and runs `claude -p` for commands sent from the notch.
@MainActor
@Observable
final class ClaudeProvider: AIProvider {
    /// Which model notch commands use. Sonnet by default: the notch is for quick tasks, and
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
    private(set) var availability: ProviderAvailability = .checking
    private(set) var isRunningCommand = false

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

    /// Commands are only sent with a subscription login. An API-key / Console login bills per
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

    func sendPrompt(_ prompt: String) {
        guard !isRunningCommand else { return }
        Task {
            if availability != .ready { await checkAvailability() }
            guard availability == .ready, let executable else {
                status.handle(.failed(availability.message ?? "Claude Code unavailable"))
                return
            }
            let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let shell = await ProcessService.shell.value
            // Headless run: file edits are allowed, other tools that need permission are refused
            // (there is nobody to answer the prompt).
            let process = StreamingProcess(
                executable: executable,
                arguments: ["-p", prompt, "--output-format", "stream-json", "--verbose",
                            "--permission-mode", "acceptEdits"] + model.flag,
                directory: directory,
                environment: ProcessService.agentEnvironment(shell: shell))
            process.onLine = { [weak self] line in
                guard let entry = ClaudeTranscriptParser.parse(line) else { return }
                if case .promptSubmitted = entry.event { return }
                self?.status.handle(entry.event)
            }
            process.onExit = { [weak self] code, errors in
                guard let self else { return }
                self.isRunningCommand = false
                self.process = nil
                guard self.status.state.isBusy else { return }
                if code == 0 {
                    self.status.handle(.completed(nil))
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
