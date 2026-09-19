import Foundation
import Testing
@testable import NotchAI

@MainActor
struct AgentStatusTests {
    @Test func promptThenToolsBuildActivityList() {
        let status = AgentStatus()
        status.handle(.promptSubmitted("Fix the login layout"))
        #expect(status.state == .thinking)
        #expect(status.currentTask == "Fix the login layout")

        status.handle(.toolStarted("Reading LoginView.swift"))
        status.handle(.toolFinished)
        status.handle(.toolStarted("Editing LoginView.swift"))
        #expect(status.state == .working)
        #expect(status.activities.map(\.isDone) == [true, false])
    }

    @Test func approvalThenCompletionReturnsToIdle() async throws {
        let status = AgentStatus()
        status.handle(.promptSubmitted("x"))
        status.handle(.approvalRequested("Allow Bash?"))
        #expect(status.state == .waitingForApproval)
        #expect(status.detail == "Allow Bash?")

        status.handle(.completed("Done"))
        #expect(status.state == .completed)
        try await Task.sleep(for: AgentStatus.completedHold + .milliseconds(300))
        #expect(status.state == .idle)
    }

    @Test func staleBusySessionExpires() {
        let status = AgentStatus()
        status.handle(.promptSubmitted("x"), at: Date(timeIntervalSinceNow: -700))
        status.expireIfStale(after: 600)
        #expect(status.state == .idle)
    }

    @Test func activityListIsCapped() {
        let status = AgentStatus()
        for index in 0..<10 { status.handle(.toolStarted("step \(index)")) }
        #expect(status.activities.count == AgentStatus.maxActivities)
        #expect(status.activities.last?.text == "step 9")
    }

    @Test func errorKeepsMessage() {
        let status = AgentStatus()
        status.handle(.failed("boom"))
        #expect(status.state == .error)
        #expect(status.detail == "boom")
    }

    @Test func titleFillsEmptyTaskWithoutChangingState() async throws {
        let status = AgentStatus()
        status.handle(.completed(nil))
        status.handle(.taskTitle("macOS notch app"))
        #expect(status.currentTask == "macOS notch app")
        #expect(status.state == .completed)
        try await Task.sleep(for: AgentStatus.completedHold + .milliseconds(300))
        #expect(status.state == .idle)   // the title did not cancel the return to idle

        status.handle(.promptSubmitted("Fix it"))
        status.handle(.taskTitle("other"))
        #expect(status.currentTask == "Fix it")
    }
}
