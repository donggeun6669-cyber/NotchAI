import Foundation
import Observation

/// Providers, the desk (music, clipboard, shelf, timer) and the launcher list.
@MainActor
@Observable
final class AppModel {
    let providers: [any AIProvider]
    let desk = DeskModel()
    /// DEAN's schedule file (appointments, deadlines, Reminders to-dos) for the calendar.
    let schedule = ScheduleService()
    /// One-click openers: the sites in daily use and each project's own page.
    let launcher = LauncherService()

    func provider(_ kind: ProviderKind) -> any AIProvider {
        providers.first { $0.kind == kind } ?? providers[0]
    }

    /// Every agent idle: the collapsed notch can shrink to just the characters.
    var allIdle: Bool { providers.allSatisfy { $0.displayState == .idle } }

    @ObservationIgnored private var pollTimer: Timer?

    init(providers: [any AIProvider] = [ClaudeProvider(), GPTProvider()]) {
        self.providers = providers
    }

    func start() {
        providers.forEach { $0.start() }
        desk.start()
        schedule.start()
        pollAll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
    }


    private func pollAll() {
        providers.forEach { $0.poll() }
        desk.poll()
        schedule.poll()
    }
}
