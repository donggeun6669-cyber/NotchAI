import AppKit
import SwiftUI

/// NotchDesk: the desk half of NotchAI made for anyone — a calendar from Calendar.app, the
/// recorder with on-device transcription, music, clipboard, shelf, timer and the places worth
/// one click. No coding agents, no DEAN: it shares the notch, desk and recording code with
/// NotchAI and brings its own app model, calendar source and collapsed notch.
@main
struct NotchDeskApp: App {
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
        // The panel goes on screen before anything waits on a privacy prompt.
        let controller = NotchWindowController(app: app)
        // `open NotchDesk.app --args -startExpanded YES` keeps the panel open (screenshots).
        controller.show(startExpanded: UserDefaults.standard.bool(forKey: "startExpanded"))
        notchController = controller
        app.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.desk.music.stop()   // do not leave the Now Playing helper running
    }
}
