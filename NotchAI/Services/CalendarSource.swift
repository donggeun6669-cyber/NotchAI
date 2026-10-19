import AppKit
import SwiftUI

/// One appointment or deadline on the notch calendar. Classes are not items: the calendar is for
/// what is not already on the timetable.
struct CalendarItem: Equatable, Identifiable, Sendable {
    enum Kind: Sendable { case deadline, appointment }

    let id = UUID()
    /// First day (with the time when there is one).
    var date: Date
    /// Last day; the same day for anything that is not a period.
    var end: Date
    /// "18:00", or "" for all day.
    var time: String
    var title: String
    var kind: Kind
    /// The calendar's own colour, when the item comes from one (Calendar.app). Nil: by kind.
    var color: Color? = nil

    var spansDays: Bool { !Calendar.current.isDate(date, inSameDayAs: end) }

    /// Whether this item is on `day` (any time that day).
    func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: day)
        return calendar.startOfDay(for: date) <= day && day <= calendar.startOfDay(for: end)
    }
}

/// An open to-do shown under a day.
struct CalendarToDo: Equatable, Identifiable, Sendable {
    let id = UUID()
    var title: String
    /// The planned day; nil when it has none.
    var date: Date?
}

/// Something the calendar header should say about where its data comes from.
struct CalendarNotice: Equatable {
    var text: String
    var help: String
    /// A button that fixes it (open System Settings), when there is one.
    var actionTitle: String? = nil
    var action: URL? = nil
}

/// Where the notch calendar gets its days from: DEAN's schedule file in NotchAI, Calendar.app in
/// NotchDesk. The calendar view only asks these questions.
@MainActor
protocol CalendarSource: AnyObject {
    func items(on day: Date) -> [CalendarItem]
    func todos(on day: Date, now: Date) -> [CalendarToDo]
    var notice: CalendarNotice? { get }
    /// Dots are red for deadlines and hollow for appointments, with a legend; otherwise each item
    /// is drawn in its calendar's colour.
    var showsKindLegend: Bool { get }
    /// What the empty list calls the things it shows ("약속·마감·할 일" / "일정").
    var emptyWord: String { get }
}

/// Day arithmetic shared by the calendar view and its sources.
enum CalendarMath {
    /// Days until a date: 0 is today.
    nonisolated static func daysLeft(_ date: Date, from now: Date = .now) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// `count` weeks of days, Monday first, starting `before` weeks earlier than the week that holds `now`.
    nonisolated static func weeks(from now: Date, before: Int = 0, count: Int = 3) -> [[Date]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let back = (calendar.component(.weekday, from: today) + 5) % 7   // Monday → 0, Sunday → 6
        guard let monday = calendar.date(byAdding: .day, value: -back - before * 7, to: today) else { return [] }
        return (0..<count).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: monday) }
        }
    }
}
