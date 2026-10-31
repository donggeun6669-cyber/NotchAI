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
        // The 결재 panel beside the open notch (2026-11-01 5차 · 6차). Its height comes from a copy of
        // its content laid out without scrolling, measured a few times a second while it is up.
        let approvals = app.approvals
        let measure = NSHostingView(rootView: ApprovalSidePanel(approvals: approvals, scrolls: false))
        var measured: (at: Date, height: CGFloat) = (.distantPast, 0)
        controller.beside = NotchBeside(
            width: ApprovalSidePanel.width,
            isWanted: { approvals.wantsPanel },
            contentHeight: {
                if Date.now.timeIntervalSince(measured.at) > 0.25 {
                    measure.rootView = ApprovalSidePanel(approvals: approvals, scrolls: false)
                    measure.layoutSubtreeIfNeeded()
                    measured = (.now, measure.fittingSize.height)
                }
                return measured.height
            },
            makeView: {
                let hosting = NSHostingView(rootView: ApprovalSidePanel(approvals: approvals))
                hosting.sizingOptions = []
                return hosting
            })
        // `open NotchAI.app --args -startExpanded YES` keeps the panel open (for screenshots / debugging).
        controller.show(startExpanded: UserDefaults.standard.bool(forKey: "startExpanded"))
        notchController = controller
        app.start()
        Logger(subsystem: "com.dongeun.NotchAI", category: "permissions")
            .info("accessibility (media keys) allowed: \(MediaKeys.isAllowed, privacy: .public)")
        // `open NotchAI.app --args -requestPermissions YES` shows all permission prompts at once.
        if UserDefaults.standard.bool(forKey: "requestPermissions") { Permissions.requestAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.desk.music.stop()   // do not leave the Now Playing helper running
    }
}
