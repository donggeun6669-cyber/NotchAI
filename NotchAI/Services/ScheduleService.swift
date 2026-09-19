import Foundation
import Observation

/// Today's classes and the nearest deadlines, read from the file DEAN's `schedule-sync` already
/// writes for the desktop widget. Read-only, and the notch says when that file is out of date
/// instead of inventing anything.
@MainActor
@Observable
final class ScheduleService {
    static let dataURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.woodsign.widgy/dean_schedule.json")
    /// The widget file is rebuilt by `calendar_sync.py`; older than this and it is probably stale.
    static let staleAfter: TimeInterval = 36 * 3600

    struct ClassSlot: Equatable, Identifiable, Sendable {
        let id = UUID()
        var start: Date
        var end: Date
        var name: String
        var room: String
        var note: String
    }

    struct Deadline: Equatable, Identifiable, Sendable {
        let id = UUID()
        var date: Date
        var time: String
        var title: String
    }

    struct Snapshot: Equatable, Sendable {
        var updated: Date?
        var classes: [ClassSlot] = []
        var deadlines: [Deadline] = []
        var events: [Deadline] = []
    }

    private(set) var snapshot = Snapshot()
    private(set) var fileMissing = false

    private var lastModified: Date?

    var isStale: Bool {
        guard let updated = snapshot.updated else { return true }
        return Date.now.timeIntervalSince(updated) > Self.staleAfter
    }

    /// The class or event happening now, or the next one today / soon.
    var nextClass: ClassSlot? {
        let now = Date.now
        return snapshot.classes.first { $0.end > now }
    }

    /// Deadlines that have not passed, soonest first.
    func upcomingDeadlines(limit: Int = 3, now: Date = .now) -> [Deadline] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        return (snapshot.deadlines + snapshot.events)
            .filter { $0.date >= startOfToday }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Days until a deadline: 0 is today.
    nonisolated static func daysLeft(_ date: Date, from now: Date = .now) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    func poll() {
        let modified = try? Self.dataURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let modified else {
            fileMissing = true
            return
        }
        fileMissing = false
        guard modified != lastModified else { return }
        lastModified = modified
        guard let data = try? Data(contentsOf: Self.dataURL) else { return }
        snapshot = Self.parse(data)
    }

    /// The widget file: CL = classes, DL = deadlines, EV = events (dates are "MM-DD").
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
            snapshot.deadlines.append(Deadline(date: day, time: row[1], title: row[2]))
        }

        for row in object["EV"] as? [[String]] ?? [] where row.count >= 5 {
            guard let day = date(row[0], time: row[2], now: now) else { continue }
            snapshot.events.append(Deadline(date: day, time: row[2], title: row[4]))
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
