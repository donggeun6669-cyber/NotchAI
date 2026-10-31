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
    /// The assistant on the always-on desktop (2026-11-01): its light beside the notch, and in the
    /// open panel its jobs and a conversation with it.
    let jarvis: JarvisService
    let chat: JarvisChat
    let approvals: JarvisApprovals
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
        let jarvis = JarvisService()
        self.jarvis = jarvis
        chat = JarvisChat(jarvis: jarvis)
        approvals = JarvisApprovals(jarvis: jarvis)
    }

    func start() {
        features.onChange = { [weak self] feature, on in self?.switched(feature, on: on) }
        for feature in features.enabled { switched(feature, on: true, resize: false) }
        if !features.deskTabs.contains(desk.tab), let first = features.deskTabs.first { desk.tab = first }
        jarvis.start()   // polls on its own clock, with its own back-off
        openApprovalForScreenshots()
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

    /// `open NotchAI.app --args -startExpanded YES -jarvisOpenApproval <id|list> [-jarvisApprovalStep confirm]`
    /// shows the 결재함 without clicking (screenshots, like `-startExpanded`).
    private func openApprovalForScreenshots() {
        guard let target = UserDefaults.standard.string(forKey: "jarvisOpenApproval"), !target.isEmpty else { return }
        approvals.open()
        guard target != "list" else { return }
        Task {
            await approvals.show(target)
            if UserDefaults.standard.string(forKey: "jarvisApprovalStep") == "confirm" {
                approvals.ask(.approve, now: .distantPast)
            }
        }
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

    /// The open panel (2026-11-01, 「노치 화면 아까처럼 더 크게」): Jarvis on the left where the
    /// calendar was, the recorder and the sites on the right — the size it had before. Without
    /// Jarvis or anything else for the left, just the right column.
    static let panelSize = CGSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.expandedBodyHeight)
    static let rightColumnWidth: CGFloat = 236
    static let panelPadding = (horizontal: CGFloat(18), top: CGFloat(6), bottom: CGFloat(12))
    static let sectionSpacing: CGFloat = 8
    /// The compact recorder: the four situations, the device, the 3-second check.
    static let recorderHeight: CGFloat = 182
    /// The title and three rows of two sites; more scroll.
    static let launcherHeight: CGFloat = 96
    static let agentsHeight: CGFloat = 58

    static func layout(features: NotchFeatures, jarvis: Bool) -> NotchLayout {
        let agents = features.isOn(.agents)
        // The characters share the wings with the recorder's mark and Jarvis's light.
        var layout = NotchLayout(narrowWing: agents ? 54 : NotchGeometry.compactWingWidth,
                                 wideWing: agents ? 104 : 80, body: panelSize)
        if !jarvis && !features.hasLeftColumn {
            let gap = sectionSpacing * 2 + 1
            var height = recorderHeight
            if features.isOn(.launcher) { height += gap + launcherHeight }
            if agents { height += gap + agentsHeight }
            layout.body = CGSize(width: rightColumnWidth + panelPadding.horizontal * 2,
                                 height: panelPadding.top + height + panelPadding.bottom)
        }
        return layout
    }
}
