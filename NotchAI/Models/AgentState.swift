import Foundation
import Observation

enum AgentState: Equatable {
    case idle
    case thinking
    case working
    case waitingForApproval
    case completed
    /// The turn is over and the next move is the user's: what `completed` settles into, until the
    /// user writes again (or `replyWindow` passes). Not the same as approval, which blocks a tool.
    case awaitingReply
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .working: "Working"
        case .waitingForApproval: "Approve?"
        case .completed: "Done"
        case .awaitingReply: "Your turn"
        case .error: "Error"
        }
    }

    var isBusy: Bool { self == .thinking || self == .working || self == .waitingForApproval }
}

/// Something that happened in a Claude Code / Codex session, already translated from the
/// tool-specific log format.
enum AgentEvent: Equatable {
    case promptSubmitted(String)
    /// A name for the session (title or last prompt); only used when no prompt is known yet.
    case taskTitle(String)
    case thinking
    case toolStarted(String)
    case toolFinished
    case approvalRequested(String?)
    case completed(String?)
    case failed(String)
    case interrupted
}

/// The state machine for one provider: turns events into state, current task and recent activity.
@MainActor
@Observable
final class AgentStatus {
    static let completedHold: Duration = .seconds(3)
    static let errorHold: Duration = .seconds(10)
    /// How long a finished turn keeps waiting for the user's answer before it is just idle.
    static let replyWindow: TimeInterval = 3600
    static let maxActivities = 4

    private(set) var state: AgentState = .idle
    private(set) var currentTask: String?
    private(set) var activities: [TaskActivity] = []
    /// Short message shown for completed / error / approval.
    private(set) var detail: String?
    private(set) var lastEventDate: Date?

    @ObservationIgnored private var settleTask: Task<Void, Never>?

    func handle(_ event: AgentEvent, at date: Date = .now) {
        // A title is metadata, not activity: it must not restart timers or change the state.
        if case .taskTitle(let title) = event {
            if currentTask == nil { currentTask = title }
            return
        }
        settleTask?.cancel()
        lastEventDate = date

        switch event {
        case .promptSubmitted(let prompt):
            currentTask = prompt
            activities = []
            detail = nil
            state = .thinking
        case .taskTitle:
            break
        case .thinking:
            finishRunningActivities()
            detail = nil
            state = .thinking
        case .toolStarted(let description):
            finishRunningActivities()
            activities.append(TaskActivity(text: description, isDone: false, date: date))
            if activities.count > Self.maxActivities { activities.removeFirst(activities.count - Self.maxActivities) }
            detail = nil
            state = .working
        case .toolFinished:
            finishRunningActivities()
            state = .thinking
        case .approvalRequested(let message):
            detail = message
            state = .waitingForApproval
        case .completed(let message):
            finishRunningActivities()
            detail = message
            state = .completed
            settle(after: Self.completedHold, into: .awaitingReply)
        case .failed(let message):
            detail = message
            state = .error
            settle(after: Self.errorHold, into: .idle)
        case .interrupted:
            finishRunningActivities()
            detail = nil
            state = .idle
        }
    }

    /// A session that stopped writing while busy (closed window, crash) goes back to idle.
    /// A finished turn nobody answered within `replyWindow` stops waiting too.
    func expireIfStale(now: Date = .now, after interval: TimeInterval) {
        guard let last = lastEventDate else { return }
        let quiet = now.timeIntervalSince(last)
        if state == .awaitingReply, quiet > Self.replyWindow {
            state = .idle
            return
        }
        guard state.isBusy, quiet > interval else { return }
        finishRunningActivities()
        state = .idle
    }

    private func finishRunningActivities() {
        for index in activities.indices where !activities[index].isDone {
            activities[index].isDone = true
        }
    }

    private func settle(after delay: Duration, into next: AgentState) {
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.state = next
        }
    }
}
