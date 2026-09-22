import AppKit
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude
    case gpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .gpt: "GPT"
        }
    }

    var nsAccent: NSColor {
        switch self {
        case .claude: NSColor(srgbRed: 0.88, green: 0.48, blue: 0.29, alpha: 1)   // Claude orange, kept intentionally
        case .gpt: NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)   // OpenAI green #10A37F
        }
    }

    var accent: Color { Color(nsColor: nsAccent) }
}

/// Whether the provider can take commands right now, and if not, what the user has to do.
enum ProviderAvailability: Equatable {
    case checking
    case ready
    case notInstalled
    case needsLogin(String)

    var message: String? {
        switch self {
        case .checking: "Checking…"
        case .ready: nil
        case .notInstalled: "CLI not found"
        case .needsLogin(let hint): hint
        }
    }
}

/// A coding agent the notch can watch and send commands to.
/// Add a provider by conforming a new class and listing it in `AppModel`.
@MainActor
protocol AIProvider: AnyObject {
    var kind: ProviderKind { get }
    var name: String { get }
    var status: AgentStatus { get }
    var availability: ProviderAvailability { get }
    /// Folder commands run in. Defaults to the folder of the most recent session.
    var workingDirectory: URL? { get set }
    /// A command started from the notch is still running.
    var isRunningCommand: Bool { get }
    /// Open sessions, the current one's title, and plan usage.
    var overview: AgentOverview { get }
    /// The conversation held from the notch.
    var chat: ChatSession { get }

    func start()
    /// Called about once a second to pick up new session activity.
    func poll()
    func sendPrompt(_ prompt: String)
    func cancelCommand()
    /// Forget the notch conversation; the next message starts a new one.
    func newChat()
    /// A usage refresh request is in flight.
    var isRefreshingUsage: Bool { get }
    /// Sends the smallest possible request so the provider reports its current plan usage.
    func refreshUsage()
}

extension AIProvider {
    var name: String { kind.displayName }
    var currentState: AgentState { status.state }

    /// State to show. The transcript follower sees only the newest session; if another open
    /// session is busy, the provider is still working.
    var displayState: AgentState {
        status.state == .idle && overview.runningCount > 0 ? .working : status.state
    }
}

/// Where usage-refresh requests run, so they can be told apart from real sessions.
enum UsageRefresh {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchAI/usage-refresh")

    static func prepareDirectory() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
