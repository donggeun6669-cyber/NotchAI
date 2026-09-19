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
        case .claude: NSColor(srgbRed: 0.88, green: 0.48, blue: 0.29, alpha: 1)   // warm orange
        case .gpt: NSColor(srgbRed: 0.16, green: 0.72, blue: 0.62, alpha: 1)      // green / teal
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

    func start()
    /// Called about once a second to pick up new session activity.
    func poll()
    func sendPrompt(_ prompt: String)
    func cancelCommand()
}

extension AIProvider {
    var name: String { kind.displayName }
    var currentState: AgentState { status.state }
}
