import Foundation
import Observation

/// What the agents finished, failed at, or asked about while the user was away.
/// Kept on disk so it survives a restart.
@MainActor
@Observable
final class ActivityLogService {
    enum Outcome: String, Codable {
        case completed, failed, approval

        var symbol: String {
            switch self {
            case .completed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .approval: "hand.raised.fill"
            }
        }
    }

    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID()
        var provider: String
        var outcome: Outcome
        var title: String
        var detail: String?
        var date: Date

        var kind: ProviderKind? { ProviderKind(rawValue: provider) }
    }

    nonisolated static let limit = 60
    /// The same event often arrives twice (stream line and process exit).
    nonisolated static let duplicateWindow: TimeInterval = 15
    nonisolated static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchAI/activity-log.json")

    private(set) var entries: [Entry] = []
    private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
        guard persists, let data = try? Data(contentsOf: Self.fileURL) else { return }
        entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Only the three outcomes worth remembering; everything else is passing state.
    func record(_ event: AgentEvent, provider: ProviderKind, title: String?, at date: Date = .now) {
        let entry: Entry
        switch event {
        case .completed(let message):
            entry = Entry(provider: provider.rawValue, outcome: .completed,
                          title: title ?? provider.displayName, detail: message, date: date)
        case .failed(let message):
            entry = Entry(provider: provider.rawValue, outcome: .failed,
                          title: title ?? provider.displayName, detail: message, date: date)
        case .approvalRequested(let message):
            entry = Entry(provider: provider.rawValue, outcome: .approval,
                          title: title ?? provider.displayName, detail: message, date: date)
        default:
            return
        }
        add(entry)
    }

    func add(_ entry: Entry) {
        guard !Self.isDuplicate(entry, of: entries) else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    nonisolated static func isDuplicate(_ entry: Entry, of entries: [Entry]) -> Bool {
        entries.contains {
            $0.provider == entry.provider && $0.outcome == entry.outcome && $0.title == entry.title
                && abs($0.date.timeIntervalSince(entry.date)) < duplicateWindow
        }
    }

    private func save() {
        guard persists else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
