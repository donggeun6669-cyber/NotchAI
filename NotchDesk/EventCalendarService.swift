import AppKit
import EventKit
import SwiftUI

/// The notch calendar's days from Calendar.app (every calendar the Mac has: iCloud, Google,
/// Exchange, subscriptions), each event in its calendar's colour. Read-only. Asks for access once;
/// without it the calendar header says so and links to the setting.
@MainActor
@Observable
final class EventCalendarService: CalendarSource {
    enum Access: Equatable { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    private(set) var events: [CalendarItem] = []

    /// The calendar view scrolls 8 weeks back and about 21 ahead; read a little more than that.
    static let weeksBack = 9
    static let weeksAhead = 32

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var loadedDay: Date?

    func start() {
        updateAccess()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            store.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in
                    self?.updateAccess()
                    self?.reload()
                }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Once a second: a new day, or access granted in System Settings, means reading again.
    func poll(now: Date = .now) {
        let before = access
        updateAccess()
        if access != before || !(loadedDay.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false) {
            reload(now: now)
        }
    }

    func reload(now: Date = .now) {
        loadedDay = now
        guard access == .granted else { events = []; return }
        let weeks = CalendarMath.weeks(from: now, before: Self.weeksBack, count: Self.weeksBack + Self.weeksAhead)
        guard let first = weeks.first?.first, let last = weeks.last?.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .map(Self.item(from:))
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.title < $1.title }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied   // denied, restricted, or write-only (cannot read)
        }
    }

    static func item(from event: EKEvent) -> CalendarItem {
        let start: Date = event.startDate
        var end: Date = event.endDate ?? start
        // An all-day event ends at the next midnight, and so does a timed one that runs to
        // midnight: neither is on that next day.
        if end > start, event.isAllDay || Calendar.current.startOfDay(for: end) == end {
            end = end.addingTimeInterval(-1)
        }
        let time: String
        if event.isAllDay {
            time = ""
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            time = formatter.string(from: start)
        }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarItem(date: start, end: end, time: time, title: title.isEmpty ? "(제목 없음)" : title,
                            kind: .appointment, color: event.calendar.map { Color(nsColor: $0.color) })
    }

    // MARK: CalendarSource

    func items(on day: Date) -> [CalendarItem] {
        events.filter { $0.covers(day) }
    }

    func todos(on day: Date, now: Date) -> [CalendarToDo] { [] }

    var notice: CalendarNotice? {
        switch access {
        case .granted: nil
        case .unknown: CalendarNotice(text: "캘린더 권한 확인 중", help: "처음 열 때 캘린더 접근을 물어봅니다")
        case .denied:
            CalendarNotice(text: "캘린더 접근 꺼짐",
                           help: "시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서 NotchDesk를 켜 주세요",
                           actionTitle: "허용하기",
                           action: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))
        }
    }

    var showsKindLegend: Bool { false }
    var emptyWord: String { "일정" }
}
