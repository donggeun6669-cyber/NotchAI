import Foundation
import Observation

/// Reads the page Chrome is showing, so a command can be about "this page" without pasting the
/// link. Read-only: the notch never clicks or types in the browser itself — the agent does that
/// with its own browser tooling.
@MainActor
@Observable
final class ChromeService {
    struct Tab: Equatable {
        var title: String
        var url: String
    }

    /// The page Chrome is showing (settable so tests can supply one).
    var frontTab: Tab?
    var isAvailable: Bool { AppleScript.isRunning(bundleID: "com.google.Chrome") }
    /// Commands are sent with the current page attached.
    var attachesTab = UserDefaults.standard.bool(forKey: "attachChromeTab") {
        didSet {
            UserDefaults.standard.set(attachesTab, forKey: "attachChromeTab")
            lastRefresh = .distantPast   // the next poll (within a second) picks up the page
        }
    }

    private var isRefreshing = false
    private var lastRefresh = Date.distantPast

    /// Only reads Chrome while the feature is switched on, so macOS never asks for permission
    /// because of something the user did not turn on.
    func poll(interval: TimeInterval = 4) {
        guard attachesTab, isAvailable, !isRefreshing,
              Date.now.timeIntervalSince(lastRefresh) >= interval else {
            if !isAvailable { frontTab = nil }
            return
        }
        lastRefresh = .now
        isRefreshing = true
        Task {
            let tab = await Self.readFrontTab()
            isRefreshing = false
            if tab != frontTab { frontTab = tab }
        }
    }

    static func readFrontTab() async -> Tab? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set t to active tab of front window
            return (title of t) & "\\n" & (URL of t)
        end tell
        """
        guard let output = await AppleScript.run(script).value else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return Tab(title: parts[0], url: parts[1])
    }

    /// Prompt text with the page prepended, when the user asked for that.
    func decorate(_ prompt: String) -> String {
        guard attachesTab, let tab = frontTab else { return prompt }
        return """
        The user is looking at this page in Chrome:
        \(tab.title)
        \(tab.url)

        \(prompt)
        """
    }
}
