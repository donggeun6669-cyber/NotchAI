import Foundation
import Observation

/// The non-agent half of the notch: music, clipboard history, file shelf, timer and the voice
/// recorder. Shared by NotchAI and NotchDesk; each app hands in the recorder it records with.
@MainActor
@Observable
final class DeskModel {
    let music = NowPlayingService()
    let clipboard = ClipboardService()
    let shelf = ShelfService()
    let focus = FocusTimerService()
    let recorder: RecorderService

    var tab: DeskView.Tab = .music {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "deskTab") }
    }

    /// How long a new track is shown in the collapsed notch before it goes back to the agent status.
    static let trackPeekDuration: TimeInterval = 4

    init(recorder: RecorderService = RecorderService()) {
        self.recorder = recorder
        if let saved = UserDefaults.standard.string(forKey: "deskTab"),
           let tab = DeskView.Tab(rawValue: saved) {
            self.tab = tab
        }
    }

    func start() {
        music.start()
    }

    func poll() {
        music.poll()
        clipboard.poll()
        focus.poll()
        recorder.poll()
    }

    /// A track that started in the last few seconds, for the collapsed notch peek.
    var peekingTrack: NowPlayingService.Track? {
        guard let track = music.track, track.isPlaying, let changedAt = music.changedAt,
              Date.now.timeIntervalSince(changedAt) < Self.trackPeekDuration else { return nil }
        return track
    }
}
