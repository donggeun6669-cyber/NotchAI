import AppKit

/// Asks for the three permissions the desk features need, one after another, so the user can
/// grant them in one sitting instead of meeting each prompt at a random moment.
@MainActor
enum Permissions {
    static func requestAll() {
        Task {
            // 1. Accessibility — playback buttons send the system media keys.
            if !MediaKeys.isAllowed { MediaKeys.askForPermission() }
            try? await Task.sleep(for: .seconds(1.5))

            // 2. Automation (Chrome) — reading the YouTube Music / YouTube tab.
            if AppleScript.isRunning(bundleID: "com.google.Chrome") {
                _ = await AppleScript.run("tell application \"Google Chrome\" to count windows")
            }
            try? await Task.sleep(for: .seconds(1))

            // 3. Clipboard — reading what another app copied shows macOS's paste prompt.
            _ = NSPasteboard.general.string(forType: .string)
        }
    }
}
