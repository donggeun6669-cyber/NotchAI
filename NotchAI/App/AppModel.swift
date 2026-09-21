import Foundation
import Observation

/// Providers, the desk (music / clipboard / shelf / Chrome), the panes above it (agent activity,
/// repositories, the log, the launcher), and which provider the notch shows.
@MainActor
@Observable
final class AppModel {
    let providers: [any AIProvider]
    let desk = DeskModel()
    /// Repositories with work that is not committed or pushed.
    let git = GitStatusService()
    /// What the agents finished, failed at, or asked about.
    let activityLog = ActivityLogService()
    /// One-click openers for folders, the schedule board and GitHub.
    let launcher = LauncherService()

    var mainTab: MainPaneView.Tab = .activity {
        didSet { UserDefaults.standard.set(mainTab.rawValue, forKey: "mainTab") }
    }

    var selectedKind: ProviderKind {
        didSet { UserDefaults.standard.set(selectedKind.rawValue, forKey: "provider") }
    }

    /// What is typed in the command field. The desk can put things here too.
    var draft = ""
    /// Bumped when something asks for the command field to take focus.
    private(set) var focusRequestedAt: Date?

    /// Adds text (a clipboard entry, a file path) to the command being written.
    func insertIntoDraft(_ text: String) {
        draft = draft.isEmpty ? text : draft + " " + text
        focusRequestedAt = .now
    }

    var selected: any AIProvider { provider(selectedKind) }

    func provider(_ kind: ProviderKind) -> any AIProvider {
        providers.first { $0.kind == kind } ?? providers[0]
    }

    /// Every agent idle: the collapsed notch can shrink to just the characters.
    var allIdle: Bool { providers.allSatisfy { $0.displayState == .idle } }

    @ObservationIgnored private var pollTimer: Timer?

    init(providers: [any AIProvider] = [ClaudeProvider(), GPTProvider()]) {
        self.providers = providers
        selectedKind = UserDefaults.standard.string(forKey: "provider").flatMap(ProviderKind.init) ?? .claude
        if let saved = UserDefaults.standard.string(forKey: "mainTab"),
           let tab = MainPaneView.Tab(rawValue: saved), tab != .chat {
            mainTab = tab
        }
    }

    func start() {
        for provider in providers {
            provider.status.onEvent = { [weak self, weak provider] event, date in
                guard let self, let provider else { return }
                self.activityLog.record(event, provider: provider.kind,
                                        title: provider.status.currentTask ?? provider.overview.currentTitle,
                                        at: date)
            }
            provider.start()
        }
        desk.start()
        git.refresh()
        pollAll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
    }

    /// Sends a command to the selected provider, with the Chrome page attached if asked for.
    func send(_ prompt: String) {
        selected.sendPrompt(desk.chrome.decorate(prompt))
        // The reply has to be visible somewhere, so sending switches to the conversation.
        mainTab = .chat
    }

    private func pollAll() {
        providers.forEach { $0.poll() }
        desk.poll()
        git.poll()
    }
}
