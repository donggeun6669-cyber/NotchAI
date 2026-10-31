import Foundation
import Observation

/// Everything NotchDesk shows: the desk (music, clipboard, shelf, timer, recorder), the launcher,
/// Calendar.app and the transcriber.
@MainActor
@Observable
final class AppModel {
    /// The Mac's sound through the built-in tap, as in 강의녹음: nothing to install.
    let desk = DeskModel(recorder: RecorderService(macSound: .systemTap))
    let launcher = LauncherService()
    let calendar = EventCalendarService()
    let transcriber = Transcriber()

    /// Nothing to say beside the notch: it shrinks to its narrow wings. The window controller
    /// asks this under NotchAI's name for it.
    var allIdle: Bool { !desk.recorder.isRunning }

    /// The window controller asks these of each app: NotchDesk keeps the standard sizes and
    /// the narrow wings it has had since 2026-10-19.
    var notchLayout: NotchLayout { NotchLayout() }
    var collapsedIsNarrow: Bool { true }

    @ObservationIgnored private var pollTimer: Timer?

    func start() {
        desk.start()
        calendar.start()
        pollAll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
    }

    private func pollAll() {
        desk.poll()
        calendar.poll()
    }
}
