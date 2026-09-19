import AppKit
import SwiftUI

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

        app.start()
        let controller = NotchWindowController(app: app)
        // `open NotchAI.app --args -startExpanded YES` keeps the panel open (for screenshots / debugging).
        controller.show(startExpanded: UserDefaults.standard.bool(forKey: "startExpanded"))
        notchController = controller
    }
}
