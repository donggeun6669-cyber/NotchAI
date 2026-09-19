import AppKit
import SwiftUI
import os

@main
struct NotchAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No regular windows; the notch panel is managed by AppKit in AppDelegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests load the app as their host; don't put a panel over the notch then.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Put the panel on screen before anything reads files: if a read waits on a macOS privacy
        // prompt, the notch is already there (and the prompt has an app with a window to show for).
        let controller = NotchWindowController(app: app)
        // `open NotchAI.app --args -startExpanded YES` keeps the panel open (for screenshots / debugging).
        controller.show(startExpanded: UserDefaults.standard.bool(forKey: "startExpanded"))
        notchController = controller
        app.start()
        Logger(subsystem: "com.dongeun.NotchAI", category: "permissions")
            .info("accessibility (media keys) allowed: \(MediaKeys.isAllowed, privacy: .public)")
        // `open NotchAI.app --args -requestPermissions YES` shows all permission prompts at once.
        if UserDefaults.standard.bool(forKey: "requestPermissions") { Permissions.requestAll() }
    }
}
