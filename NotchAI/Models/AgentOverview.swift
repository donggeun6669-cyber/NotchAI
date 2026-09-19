import Foundation

/// The numbers worth seeing at a glance for one provider: which sessions are open and running,
/// what the current one is called, and how much of the plan's usage window is gone.
struct AgentOverview: Equatable {
    struct Session: Equatable, Identifiable {
        var id: String
        var title: String
        var isBusy: Bool
        var directory: String?
        var updatedAt: Date
    }

    struct Usage: Equatable, Codable {
        /// 0–100, for the short (5-hour) window and the weekly window.
        var shortWindowPercent: Double?
        var weeklyPercent: Double?
        var shortWindowResetsAt: Date?
        var weeklyResetsAt: Date?
        var plan: String?
        /// When these numbers were read; usage is only as fresh as its source.
        var observedAt: Date
    }

    var sessions: [Session] = []
    /// Subagents currently writing (Claude's background helpers).
    var subagentsRunning = 0
    var usage: Usage?

    var runningCount: Int { sessions.filter(\.isBusy).count }

    /// The session to name in the header: the most recent busy one, else the most recent one.
    var currentTitle: String? {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        return (sorted.first(where: \.isBusy) ?? sorted.first)?.title
    }
}
