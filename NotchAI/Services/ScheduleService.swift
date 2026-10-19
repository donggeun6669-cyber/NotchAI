import Foundation
import Observation

/// Appointments and deadlines for the notch calendar, read from the file DEAN's `schedule-sync`
/// already writes for the 상황판 (`sync_all.py` rebuilds it from the originals). Read-only:
/// nothing here has to be kept up to date by hand, and the notch says when that file is old
/// instead of inventing anything.
@MainActor
@Observable
final class ScheduleService {
    /// The one copy inside DEAN (2026-09-22). The old copy in Widgy's group container stopped
    /// being written that day and only goes stale.
    nonisolated static let dataURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/DEAN/06_RESOURCES/setup/schedule-sync/dean_schedule.json")
    /// The file is rebuilt by `sync_all.py`; older than this and it is probably stale.
    static let staleAfter: TimeInterval = 36 * 3600

    struct ClassSlot: Equatable, Identifiable, Sendable {
        let id = UUID()
        var start: Date
        var end: Date
        var name: String
        var room: String
        var note: String
    }

    /// One appointment or deadline. Classes are not items: the calendar is for what is not
    /// already on the timetable.
    struct Item: Equatable, Identifiable, Sendable {
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

        var spansDays: Bool { !Calendar.current.isDate(date, inSameDayAs: end) }

        /// Whether this item is on `day` (any time that day).
        func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
            let day = calendar.startOfDay(for: day)
            return calendar.startOfDay(for: date) <= day && day <= calendar.startOfDay(for: end)
        }
    }

    /// An open to-do from the Reminders list 「오늘 할 일」, which `todo_sync.py` snapshots into the
    /// same file every 15 minutes (unfinished ones only).
    struct ToDo: Equatable, Identifiable, Sendable {
        let id = UUID()
        var title: String
        /// The planned day; nil when the reminder has none.
        var date: Date?
    }

    struct Snapshot: Equatable, Sendable {
        var updated: Date?
        var classes: [ClassSlot] = []
        var deadlines: [Item] = []
        var events: [Item] = []
        var todos: [ToDo] = []

        /// Deadlines and appointments together, in date order (all-day ones first on a day).
        var items: [Item] {
            (deadlines + events).sorted {
                $0.date != $1.date ? $0.date < $1.date : $0.kind == .deadline && $1.kind == .appointment
            }
        }
    }

    private(set) var snapshot = Snapshot()
    private(set) var fileMissing = false

    private var lastModified: Date?
    private var isReading = false

    var isStale: Bool {
        guard let updated = snapshot.updated else { return true }
        return Date.now.timeIntervalSince(updated) > Self.staleAfter
    }

    /// Everything on one day.
    func items(on day: Date) -> [Item] {
        snapshot.items.filter { $0.covers(day) }
    }

    /// To-dos for a day. Today also gets the undated ones and the ones left over from earlier days.
    func todos(on day: Date, now: Date = .now) -> [ToDo] {
        Self.todos(snapshot.todos, on: day, now: now)
    }

    nonisolated static func todos(_ todos: [ToDo], on day: Date, now: Date = .now) -> [ToDo] {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        return todos.filter { todo in
            guard let date = todo.date else { return target == today }
            let planned = calendar.startOfDay(for: date)
            return target == today ? planned <= today : planned == target
        }
    }

    /// What is still ahead from today through `last`: anything starting in that window, and a
    /// period that is already running.
    func upcoming(through last: Date, now: Date = .now) -> [Item] {
        Self.upcoming(snapshot.items, through: last, now: now)
    }

    nonisolated static func upcoming(_ items: [Item], through last: Date, now: Date = .now) -> [Item] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let lastDay = calendar.startOfDay(for: last)
        return items.filter {
            calendar.startOfDay(for: $0.end) >= today && calendar.startOfDay(for: $0.date) <= lastDay
        }
    }

    /// Days until a date: 0 is today.
    nonisolated static func daysLeft(_ date: Date, from now: Date = .now) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// `count` weeks of days, Monday first, starting `before` weeks ahead of the week that holds `now`.
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

    /// The file is read off the main thread: a main-thread read here once froze the app before
    /// its window even appeared (it used to live in another app's container).
    func poll() {
        guard !isReading else { return }
        isReading = true
        let known = lastModified
        Task.detached(priority: .utility) {
            let url = ScheduleService.dataURL
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let data = modified != nil && modified != known ? try? Data(contentsOf: url) : nil
            await MainActor.run {
                self.isReading = false
                self.fileMissing = modified == nil
                guard let modified, modified != known, let data else { return }
                self.lastModified = modified
                self.snapshot = ScheduleService.parse(data)
            }
        }
    }

    /// The widget file: CL = classes, DL = deadlines, EV = events, TD = open to-dos (dates are
    /// "MM-DD"). EV rows are [first day, last day, start, end, title]; TD rows are [title, day].
    nonisolated static func parse(_ data: Data, now: Date = .now) -> Snapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Snapshot() }
        var snapshot = Snapshot()

        if let updated = object["updated"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            formatter.timeZone = .current
            snapshot.updated = formatter.date(from: updated)
        }

        for row in object["CL"] as? [[String]] ?? [] where row.count >= 5 {
            guard let start = date(row[0], time: row[1], now: now),
                  let end = date(row[0], time: row[2], now: now) else { continue }
            snapshot.classes.append(ClassSlot(start: start, end: end, name: row[3], room: row[4],
                                              note: row.count > 5 ? row[5] : ""))
        }
        snapshot.classes.sort { $0.start < $1.start }

        for row in object["DL"] as? [[String]] ?? [] where row.count >= 3 {
            guard let day = date(row[0], time: row[1].isEmpty ? "23:59" : row[1], now: now) else { continue }
            snapshot.deadlines.append(Item(date: day, end: day, time: row[1], title: row[2], kind: .deadline))
        }

        for row in object["EV"] as? [[String]] ?? [] where row.count >= 5 {
            guard let day = date(row[0], time: row[2], now: now) else { continue }
            // The last day is read relative to the first, so a period over New Year stays in order.
            var last = date(row[1], time: "00:00", now: day) ?? day
            if last < Calendar.current.startOfDay(for: day) { last = day }
            snapshot.events.append(Item(date: day, end: last, time: row[2], title: row[4], kind: .appointment))
        }

        for row in object["TD"] as? [[String]] ?? [] where !row.isEmpty {
            let title = row[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let day = row.count > 1 && !row[1].isEmpty ? date(row[1], time: "00:00", now: now) : nil
            snapshot.todos.append(ToDo(title: title, date: day))
        }

        return snapshot
    }

    /// "09-21" + "13:30" → a date this school year: months far in the past belong to next year.
    nonisolated static func date(_ monthDay: String, time: String, now: Date = .now) -> Date? {
        let dayParts = monthDay.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 2 else { return nil }
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = calendar.component(.year, from: now)
        components.month = dayParts[0]
        components.day = dayParts[1]
        components.hour = timeParts.first ?? 0
        components.minute = timeParts.count > 1 ? timeParts[1] : 0
        guard let candidate = calendar.date(from: components) else { return nil }
        // A date more than half a year behind is next year's (December → January).
        if candidate.timeIntervalSince(now) < -180 * 24 * 3600 {
            components.year = (components.year ?? 0) + 1
            return calendar.date(from: components)
        }
        return candidate
    }
}
