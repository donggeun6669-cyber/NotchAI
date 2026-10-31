import AppKit
import Foundation
import Observation

/// The recorder and Jarvis, which are always there, and the parts that can be switched on in the
/// `…` menu: providers, the desk (music, clipboard, shelf, timer), the calendar, the launcher.
/// Only what is switched on is started and polled (2026-11-01).
@MainActor
@Observable
final class AppModel {
    let providers: [any AIProvider]
    let desk = DeskModel()
    /// DEAN's schedule file (appointments, deadlines, Reminders to-dos) for the calendar.
    let schedule = ScheduleService()
    /// One-click openers: the sites in daily use and each project's own page.
    let launcher = LauncherService()
    /// The assistant on the always-on desktop (2026-11-01): its light beside the notch, its jobs inside.
    let jarvis = JarvisService()
    /// What is shown, and so what runs.
    let features: NotchFeatures

    var recorder: RecorderService { desk.recorder }

    func provider(_ kind: ProviderKind) -> any AIProvider {
        providers.first { $0.kind == kind } ?? providers[0]
    }

    /// Every agent idle: the collapsed notch can shrink to just the characters.
    var allIdle: Bool { providers.allSatisfy { $0.displayState == .idle } }

    /// A recording is on (or being checked or closed), or the last one failed and has not been
    /// dismissed: the wings widen for its clock or its warning. Otherwise they stay narrow.
    var collapsedIsNarrow: Bool { !recorder.isBusy && !recorder.needsAttention }

    var notchLayout: NotchLayout { Self.layout(features: features, jarvis: jarvis.isEnabled) }

    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var started: Set<NotchFeatures.Feature> = []

    init(providers: [any AIProvider] = [ClaudeProvider(), GPTProvider()],
         features: NotchFeatures = NotchFeatures()) {
        self.providers = providers
        self.features = features
    }

    func start() {
        features.onChange = { [weak self] feature, on in self?.switched(feature, on: on) }
        for feature in features.enabled { switched(feature, on: true, resize: false) }
        if !features.deskTabs.contains(desk.tab), let first = features.deskTabs.first { desk.tab = first }
        jarvis.start()   // polls on its own clock, with its own back-off
        pollAll()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
        timer.tolerance = 0.3
        pollTimer = timer
    }

    /// Starts what a part needs the first time it is switched on; music's helper process is also
    /// stopped when it is switched off. The panels are resized to what is now shown.
    private func switched(_ feature: NotchFeatures.Feature, on: Bool, resize: Bool = true) {
        if on, !started.contains(feature) {
            started.insert(feature)
            switch feature {
            case .agents: providers.forEach { $0.start() }
            case .music: desk.music.start()
            case .calendar: schedule.start()
            default: break
            }
        }
        if !on, feature == .music {
            desk.music.stop()
            started.remove(.music)
        }
        if let tab = feature.deskTab, !on, desk.tab == tab {
            desk.tab = features.deskTabs.first ?? .music
        } else if let tab = feature.deskTab, on, resize {
            desk.tab = tab
        }
        if resize { resizePanels() }
    }

    /// Something that changes the panel's size was switched (a part, or Jarvis's address).
    func resizePanels() {
        NotificationCenter.default.post(name: .notchScreensChanged, object: nil)
    }

    private func pollAll() {
        recorder.poll()
        if features.isOn(.agents) { providers.forEach { $0.poll() } }
        if features.isOn(.music) { desk.music.poll() }
        if features.isOn(.clips) { desk.clipboard.poll() }
        if features.isOn(.timer) { desk.focus.poll() }
        if features.isOn(.calendar) { schedule.poll() }
    }

    // MARK: Sizes

    /// The open panel's column of recorder, Jarvis and whatever else is on.
    static let mainColumnWidth: CGFloat = 336
    /// Calendar and desk to the left of it, when either is on.
    static let leftColumnWidth: CGFloat = 400
    static let panelPadding = (horizontal: CGFloat(18), top: CGFloat(6), bottom: CGFloat(14))
    static let sectionSpacing: CGFloat = 10
    static let recorderHeight: CGFloat = 214
    static let launcherHeight: CGFloat = 112
    static let agentsHeight: CGFloat = 58
    /// The calendar and desk need this much height to be worth showing.
    static let leftColumnMinHeight: CGFloat = 392

    /// The panel fits what is on: the recorder alone is small; each part adds its own height.
    static func layout(features: NotchFeatures, jarvis: Bool) -> NotchLayout {
        let agents = features.isOn(.agents)
        // A divider and the spacing either side of it before every part after the recorder.
        let gap = sectionSpacing * 2 + 1
        var main = recorderHeight
        if features.isOn(.launcher) { main += gap + launcherHeight }
        if jarvis { main += gap + JarvisSection.height }
        if agents { main += gap + agentsHeight }

        var height = panelPadding.top + main + panelPadding.bottom
        var width = mainColumnWidth + panelPadding.horizontal * 2
        if features.hasLeftColumn {
            height = max(height, leftColumnMinHeight)
            width += leftColumnWidth + 29   // the divider between the columns, with its spacing
        }
        // The characters share the wings with the recorder's mark and Jarvis's light.
        return NotchLayout(narrowWing: agents ? 54 : NotchGeometry.compactWingWidth,
                           wideWing: agents ? 104 : 80,
                           body: CGSize(width: width, height: height))
    }
}
