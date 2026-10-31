import Foundation
import Observation

/// Which parts of the notch are switched on (2026-11-01). The recorder and Jarvis are always
/// there; the rest start hidden because 동근님 uses the notch for recording — 「쓰는 건 녹음뿐」 —
/// and each comes back with one click in the `…` menu. A hidden part does not run at all: no
/// polling, no helper process, no file reading.
@MainActor
@Observable
final class NotchFeatures {
    enum Feature: String, CaseIterable, Identifiable {
        case calendar
        case music
        case clips
        case shelf
        case timer
        case launcher
        case agents

        var id: String { rawValue }

        var label: String {
            switch self {
            case .calendar: "달력 · 오늘 할 일"
            case .music: "음악"
            case .clips: "복사한 글"
            case .shelf: "파일 선반"
            case .timer: "타이머"
            case .launcher: "자주 가는 곳"
            case .agents: "Claude · GPT 상태"
            }
        }

        /// The desk tab this feature is, if it is one.
        var deskTab: DeskView.Tab? {
            switch self {
            case .music: .music
            case .clips: .clips
            case .shelf: .shelf
            case .timer: .focus
            default: nil
            }
        }
    }

    private(set) var enabled: Set<Feature>
    /// Called after a feature is switched, to start or stop what it runs.
    @ObservationIgnored var onChange: ((Feature, Bool) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults: nil` keeps the switches in memory only (tests).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        enabled = Set(Feature.allCases.filter { defaults?.bool(forKey: Self.key($0)) == true })
    }

    static func key(_ feature: Feature) -> String { "show." + feature.rawValue }

    func isOn(_ feature: Feature) -> Bool { enabled.contains(feature) }

    func set(_ feature: Feature, _ on: Bool) {
        guard on != isOn(feature) else { return }
        if on { enabled.insert(feature) } else { enabled.remove(feature) }
        defaults?.set(on, forKey: Self.key(feature))
        onChange?(feature, on)
    }

    /// The desk tabs that are on, in their usual order.
    var deskTabs: [DeskView.Tab] {
        DeskView.Tab.allCases.filter { tab in Feature.allCases.contains { $0.deskTab == tab && isOn($0) } }
    }

    /// Anything for the left column of the open panel (the calendar or the desk).
    var hasLeftColumn: Bool { isOn(.calendar) || !deskTabs.isEmpty }
}
