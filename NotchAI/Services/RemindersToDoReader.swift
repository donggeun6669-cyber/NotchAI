import EventKit
import Foundation
import Observation

/// The open to-dos of the Reminders list 「오늘 할 일」, read straight from Reminders and read again
/// the moment that list changes (checking one off on the Mac, or on the iPhone once iCloud brings
/// it over). Until 2026-10-19 the notch only had DEAN's schedule file, whose to-dos are a snapshot
/// taken every 15 minutes, so a ticked item stayed on the notch for up to a quarter of an hour.
///
/// Read-only. Without access, or without that list, `todos` is nil and the notch keeps using the
/// file's snapshot (`dean_schedule.json` TD), which `todo_sync.py --snapshot` now refreshes every minute.
@MainActor
@Observable
final class RemindersToDoReader {
    /// The list `todo_sync.py` fills from DEAN's TASKS.md files.
    nonisolated static let listName = "오늘 할 일"

    /// Nil: cannot read Reminders right now; use the file instead.
    private(set) var todos: [CalendarToDo]?

    @ObservationIgnored private var store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var status = EKEventStore.authorizationStatus(for: .reminder)
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var again = false

    func start() {
        if status == .notDetermined {
            store.requestFullAccessToReminders { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.poll() }
            }
        }
        listen()
        reload()
    }

    /// Once a second: access turned on (or off) in System Settings means reading again.
    func poll() {
        let now = EKEventStore.authorizationStatus(for: .reminder)
        guard now != status else { return }
        status = now
        // A store made before access was granted reads, but is never told about changes
        // (2026-10-19: the first fetch worked, later edits to the list never arrived). Start over.
        store = EKEventStore()
        listen()
        reload()
    }

    private func listen() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        guard status == .fullAccess,
              let list = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) else {
            todos = nil
            return
        }
        // A burst of changes (the sync adding several items) is read once more after the current read.
        if fetching { again = true; return }
        fetching = true
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                               calendars: [list])
        // EventKit answers on its own queue: the closure must not inherit this class's main-actor
        // isolation, or Swift's check on entry stops the app (it did on the first try, 2026-10-19).
        store.fetchReminders(matching: predicate) { @Sendable [weak self] reminders in
            let rows = Self.todos(from: (reminders ?? []).map {
                (title: $0.title, due: $0.dueDateComponents, created: $0.creationDate)
            })
            Task { @MainActor in
                guard let self else { return }
                self.fetching = false
                self.todos = rows
                if self.again {
                    self.again = false
                    self.reload()
                }
            }
        }
    }

    /// Titles and planned days in the order the file uses: by day, undated last; same day by when
    /// each was added to the list.
    nonisolated static func todos(from reminders: [(title: String?, due: DateComponents?, created: Date?)],
                                  calendar: Calendar = .current) -> [CalendarToDo] {
        reminders
            .compactMap { reminder -> (CalendarToDo, Date)? in
                let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let day = reminder.due.flatMap { due -> Date? in
                    guard let year = due.year, let month = due.month, let day = due.day else { return nil }
                    return calendar.date(from: DateComponents(year: year, month: month, day: day))
                }
                return (CalendarToDo(title: title, date: day), reminder.created ?? .distantPast)
            }
            .sorted { a, b in
                switch (a.0.date, b.0.date) {
                case let (x?, y?) where x != y: x < y
                case (nil, _?): false
                case (_?, nil): true
                default: a.1 < b.1
                }
            }
            .map(\.0)
    }
}
