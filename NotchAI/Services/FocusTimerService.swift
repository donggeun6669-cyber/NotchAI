import Foundation
import Observation

/// A stopwatch for one piece of work ("듣기 2주차 강의"), so that time actually spent is a
/// number somewhere. Finished runs are appended to a file the user can read or copy into DEAN.
@MainActor
@Observable
final class FocusTimerService {
    struct Run: Codable, Equatable, Identifiable {
        var id = UUID()
        var label: String
        var startedAt: Date
        var seconds: Int
    }

    nonisolated static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchAI/focus-log.json")
    /// Runs shorter than this are dropped: a mis-click is not a study session.
    nonisolated static let minimumSeconds = 60
    nonisolated static let keepDays = 30

    private(set) var label = ""
    private(set) var startedAt: Date?
    /// Seconds on the clock right now, updated by `poll`.
    private(set) var elapsed: TimeInterval = 0
    private(set) var runs: [Run] = []

    var isRunning: Bool { startedAt != nil }

    private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
        guard persists, let data = try? Data(contentsOf: Self.fileURL) else { return }
        runs = (try? JSONDecoder().decode([Run].self, from: data)) ?? []
    }

    func start(label: String) {
        guard !isRunning else { return }
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.label.isEmpty { self.label = "집중" }
        startedAt = .now
        elapsed = 0
    }

    /// Stops the clock and keeps the run if it was long enough.
    @discardableResult
    func stop(now: Date = .now) -> Run? {
        guard let startedAt else { return nil }
        let seconds = Int(now.timeIntervalSince(startedAt))
        self.startedAt = nil
        elapsed = 0
        guard seconds >= Self.minimumSeconds else { return nil }
        let run = Run(label: label, startedAt: startedAt, seconds: seconds)
        runs.insert(run, at: 0)
        runs = Self.pruned(runs, now: now, keepDays: Self.keepDays)
        save()
        return run
    }

    func poll() {
        guard let startedAt else { return }
        let seconds = Date.now.timeIntervalSince(startedAt)
        // Only whole seconds, so the view redraws once a second at most.
        if Int(seconds) != Int(elapsed) { elapsed = seconds }
    }

    /// Totals per label for a day, longest first.
    nonisolated static func totals(_ runs: [Run], on day: Date = .now,
                                   calendar: Calendar = .current) -> [(label: String, seconds: Int)] {
        var sums: [String: Int] = [:]
        for run in runs where calendar.isDate(run.startedAt, inSameDayAs: day) {
            sums[run.label, default: 0] += run.seconds
        }
        return sums.map { (label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.label < $1.label : $0.seconds > $1.seconds }
    }

    var todayTotals: [(label: String, seconds: Int)] { Self.totals(runs) }
    var todaySeconds: Int { todayTotals.reduce(0) { $0 + $1.seconds } }

    /// Labels used before, for one-tap restart.
    var recentLabels: [String] {
        var seen = Set<String>()
        return runs.compactMap { seen.insert($0.label).inserted ? $0.label : nil }.prefix(4).map { $0 }
    }

    nonisolated static func pruned(_ runs: [Run], now: Date, keepDays: Int) -> [Run] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return runs.filter { $0.startedAt > cutoff }
    }

    /// "1시간 05분" / "23분" / "0:42".
    nonisolated static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)초" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)분" }
        return String(format: "%d시간 %02d분", minutes / 60, minutes % 60)
    }

    /// Running clock: "12:34" or "1:02:03".
    nonisolated static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s < 3600
            ? String(format: "%d:%02d", s / 60, s % 60)
            : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// One line per run, for pasting into a log.
    func summaryText(on day: Date = .now) -> String {
        Self.totals(runs, on: day).map { "\($0.label) \(Self.duration($0.seconds))" }.joined(separator: " · ")
    }

    private func save() {
        guard persists else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(runs) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
