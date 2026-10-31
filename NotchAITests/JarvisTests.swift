import Foundation
import Testing
@testable import NotchAI

/// Answers for the server: one canned reply (or network error) per path.
private actor FakeJarvis: JarvisTransport {
    enum Reply {
        case ok(String)
        case status(Int)
        case down(URLError.Code)
    }

    var replies: [String: Reply]
    private(set) var asked: [String] = []

    init(_ replies: [String: Reply]) { self.replies = replies }

    func set(_ path: String, _ reply: Reply) { replies[path] = reply }

    func get(_ url: URL) async throws -> (Data, Int) {
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        asked.append(path)
        switch replies[path] ?? .status(404) {
        case .ok(let body): return (Data(body.utf8), 200)
        case .status(let code): return (Data("{\"detail\":\"x\"}".utf8), code)
        case .down(let code): throw URLError(code)
        }
    }

    func clearAsked() { asked = [] }
}

private let health = #"{"ok":true,"version":"0.1.0","max_concurrent":2,"jobs":{"queued":1,"running":2,"done":2,"failed":0,"cancelled":0,"interrupted":0},"recovered_at_start":[]}"#
private let jobs = #"[{"id":"a","title":"시험ⓒ 끊긴 일 다시","status":"done","model":"sonnet","progress":"완료","created_at":1793467954.566635},{"id":"b","title":"","status":"running","created_at":1793467913.5}]"#
private let base = "https://desk.example.ts.net"

struct JarvisParsingTests {
    @Test func presenceWithEveryField() throws {
        let body = #"{"state":"working","running_jobs":2,"queued_jobs":1,"approvals":0,"active_conversations":1,"last_event_at":1793467973.9,"version":"0.2.0"}"#
        let presence = try #require(JarvisPresence.parse(presence: Data(body.utf8)))
        #expect(presence.state == .working)
        #expect(presence.runningJobs == 2)
        #expect(presence.queuedJobs == 1)
        #expect(presence.activeConversations == 1)
        #expect(presence.lastEventAt == Date(timeIntervalSince1970: 1793467973.9))
        #expect(presence.version == "0.2.0")
        #expect(!presence.isDerived)
    }

    @Test func everyStateTheServerNames() {
        let names = ["idle": JarvisState.idle, "thinking": .thinking, "working": .working,
                     "needs_approval": .needsApproval, "listening": .listening, "speaking": .speaking]
        for (raw, state) in names { #expect(JarvisState(raw: raw) == state) }
        #expect(JarvisState(raw: "dreaming") == .unknown("dreaming"))
    }

    @Test func missingCountsAreZeroAndNullTimeIsNil() throws {
        let presence = try #require(JarvisPresence.parse(presence: Data(#"{"state":"idle","last_event_at":null}"#.utf8)))
        #expect(presence.runningJobs == 0 && presence.approvals == 0)
        #expect(presence.lastEventAt == nil)
    }

    @Test func noStateIsNotAPresence() {
        #expect(JarvisPresence.parse(presence: Data(#"{"detail":"Not Found"}"#.utf8)) == nil)
        #expect(JarvisPresence.parse(presence: Data("<html>".utf8)) == nil)
    }

    @Test func approvalsOutrankTheState() throws {
        let presence = try #require(JarvisPresence.parse(presence: Data(#"{"state":"working","running_jobs":1,"approvals":1}"#.utf8)))
        #expect(presence.shownState == .needsApproval)
        // The light keeps saying what Jarvis does; the waiting 결재 is a red dot beside it (5차).
        #expect(JarvisOrbState(.online(presence)) == .working(jobs: 1))
    }

    @Test func healthBecomesAPresence() throws {
        let busy = try #require(JarvisPresence.parse(health: Data(health.utf8)))
        #expect(busy.state == .working && busy.runningJobs == 2 && busy.queuedJobs == 1 && busy.isDerived)
        let queued = try #require(JarvisPresence.parse(health: Data(#"{"jobs":{"queued":1,"running":0}}"#.utf8)))
        #expect(queued.state == .thinking)
        let quiet = try #require(JarvisPresence.parse(health: Data(#"{"ok":true,"jobs":{"queued":0,"running":0}}"#.utf8)))
        #expect(quiet.state == .idle)
    }

    @Test func jobsInKorean() throws {
        let list = try #require(JarvisJob.parse(list: Data(jobs.utf8)))
        #expect(list.map(\.statusWord) == ["완료", "진행 중"])
        #expect(list[1].title == "b")   // an untitled job shows its id
        let words = ["queued", "running", "done", "failed", "cancelled", "interrupted"].map(JarvisJob.word(for:))
        #expect(words == ["대기", "진행 중", "완료", "실패", "취소", "중단"])
        #expect(JarvisJob.word(for: "paused") == "paused")
    }

    @Test func workingShowsOneSatellitePerRunningJob() {
        func orb(_ running: Int) -> JarvisOrbState? {
            JarvisOrbState(.online(JarvisPresence(state: .working, runningJobs: running, queuedJobs: 0, approvals: 0,
                                                  activeConversations: 0)))
        }
        #expect(orb(0) == .working(jobs: 1))
        #expect(orb(2) == .working(jobs: 2))
        #expect(orb(9) == .working(jobs: JarvisOrbState.maxSatellites))
    }

    @Test func offlineNeverLooksIdle() {
        #expect(JarvisOrbState(.offline(.unreachable)) == .offline)
        #expect(JarvisOrbState(.checking) == .checking)
        #expect(JarvisOrbState(.off) == nil)
    }

    @Test func addresses() {
        #expect(JarvisSettings.baseURL("desk.example.ts.net/")?.absoluteString == base)
        #expect(JarvisSettings.baseURL(" \(base) ")?.absoluteString == base)
        #expect(JarvisSettings.baseURL("http://localhost:8765")?.absoluteString == "http://localhost:8765")
        #expect(JarvisSettings.baseURL("") == nil)
        #expect(JarvisSettings.baseURL("not an address") == nil)
    }

    @Test func networkErrorsSayWhatToCheck() {
        #expect(JarvisOffline(error: URLError(.cannotFindHost)) == .nameNotFound)
        #expect(JarvisOffline(error: URLError(.timedOut)) == .unreachable)
        #expect(JarvisOffline(error: URLError(.cannotConnectToHost)) == .unreachable)
        #expect(JarvisOffline(status: 502) == .serviceDown(502))
        #expect(JarvisOffline(status: 401) == .badAnswer)
    }
}

struct JarvisBackoffTests {
    @Test func everyFewSecondsWhileItAnswers() {
        var backoff = JarvisBackoff()
        backoff.succeeded()
        #expect(backoff.nextDelay == .seconds(3))
        #expect(!backoff.isOffline)
    }

    @Test func doublesUpToAMinute() {
        var backoff = JarvisBackoff()
        var delays: [Duration] = []
        for _ in 0..<8 {
            backoff.failed()
            delays.append(backoff.nextDelay)
        }
        #expect(delays == [.seconds(3), .seconds(6), .seconds(12), .seconds(24), .seconds(48),
                           .seconds(60), .seconds(60), .seconds(60)])
        backoff.succeeded()
        #expect(backoff.nextDelay == .seconds(3))
    }

    @Test func oneBlipIsNotOffline() {
        var backoff = JarvisBackoff()
        backoff.succeeded()
        backoff.failed()
        #expect(!backoff.isOffline)
        backoff.failed()
        #expect(backoff.isOffline)
    }

    @Test func beforeAnyAnswerOneMissIsOffline() {
        var backoff = JarvisBackoff()
        backoff.failed()
        #expect(backoff.isOffline)
    }
}

@MainActor
struct JarvisServiceTests {
    @Test func presenceAndJobs() async {
        let server = FakeJarvis(["/presence": .ok(#"{"state":"thinking","running_jobs":0,"queued_jobs":0,"approvals":0,"active_conversations":1,"last_event_at":null,"version":"0.2.0"}"#),
                                 "/jobs?limit=3": .ok(jobs)])
        let jarvis = JarvisService(transport: server, address: base)
        let delay = await jarvis.pollOnce()
        #expect(delay == .seconds(3))
        #expect(jarvis.presence?.state == .thinking)
        #expect(jarvis.jobs.map(\.id) == ["a", "b"])
        #expect(await server.asked == ["/presence", "/jobs?limit=3"])
    }

    @Test func noPresenceYetFallsBackToHealth() async {
        let server = FakeJarvis(["/presence": .status(404), "/health": .ok(health), "/jobs?limit=3": .ok(jobs)])
        let jarvis = JarvisService(transport: server, address: base)
        let start = Date()
        await jarvis.pollOnce(now: start)
        #expect(jarvis.presence?.isDerived == true)
        #expect(jarvis.presence?.state == .working)
        #expect(await server.asked == ["/presence", "/health", "/jobs?limit=3"])

        // Within the minute, straight to /health; then /presence is tried again.
        await server.clearAsked()
        await jarvis.pollOnce(now: start.addingTimeInterval(10))
        #expect(await server.asked == ["/health"])

        await server.clearAsked()
        await server.set("/presence", .ok(#"{"state":"idle"}"#))
        await jarvis.pollOnce(now: start.addingTimeInterval(JarvisService.presenceRecheck + 1))
        #expect(await server.asked.first == "/presence")
        #expect(jarvis.presence?.isDerived == false)
        #expect(jarvis.presence?.state == .idle)
    }

    @Test func goesOfflineAndBacksOff() async {
        let server = FakeJarvis(["/presence": .ok(#"{"state":"idle"}"#), "/jobs?limit=3": .ok("[]")])
        let jarvis = JarvisService(transport: server, address: base)
        await jarvis.pollOnce()
        #expect(jarvis.presence?.state == .idle)

        await server.set("/presence", .down(.timedOut))
        var delay = await jarvis.pollOnce()
        // One miss: still showing the last real answer, asking again soon.
        #expect(jarvis.presence?.state == .idle)
        #expect(delay == .seconds(3))
        delay = await jarvis.pollOnce()
        #expect(jarvis.connection == .offline(.unreachable))
        #expect(delay == .seconds(6))
        delay = await jarvis.pollOnce()
        #expect(delay == .seconds(12))

        await server.set("/presence", .ok(#"{"state":"working","running_jobs":1}"#))
        delay = await jarvis.pollOnce()
        #expect(jarvis.presence?.state == .working)
        #expect(delay == .seconds(3))
    }

    @Test func tailscaleOffOnTheMac() async {
        let server = FakeJarvis(["/presence": .down(.cannotFindHost)])
        let jarvis = JarvisService(transport: server, address: base)
        #expect(jarvis.connection == .checking)
        await jarvis.pollOnce()
        #expect(jarvis.connection == .offline(.nameNotFound))
    }

    @Test func serviceDownBehindTailscale() async {
        let server = FakeJarvis(["/presence": .status(502)])
        let jarvis = JarvisService(transport: server, address: base)
        await jarvis.pollOnce()
        #expect(jarvis.connection == .offline(.serviceDown(502)))
    }

    @Test func noAddressMeansOff() async {
        let server = FakeJarvis([:])
        let jarvis = JarvisService(transport: server, address: "")
        #expect(jarvis.connection == .off)
        #expect(!jarvis.isEnabled)
        await jarvis.pollOnce()
        #expect(jarvis.connection == .off)
        #expect(await server.asked.isEmpty)
    }

    @Test func jobsFollowChangesNotEveryRound() async {
        let server = FakeJarvis(["/presence": .ok(#"{"state":"idle"}"#), "/jobs?limit=3": .ok(jobs)])
        let jarvis = JarvisService(transport: server, address: base)
        let start = Date()
        await jarvis.pollOnce(now: start)
        await server.clearAsked()
        await jarvis.pollOnce(now: start.addingTimeInterval(3))
        #expect(await server.asked == ["/presence"])

        await server.set("/presence", .ok(#"{"state":"working","running_jobs":1}"#))
        await jarvis.pollOnce(now: start.addingTimeInterval(6))
        #expect(await server.asked.last == "/jobs?limit=3")

        await server.clearAsked()
        await jarvis.pollOnce(now: start.addingTimeInterval(9 + JarvisService.jobsInterval))
        #expect(await server.asked.last == "/jobs?limit=3")
    }

    @Test func appFallsBackToTheBoardWhenMissing() throws {
        let root = try #require(URL(string: base))
        #expect(JarvisService.chatURL(base: root, appStatus: 200).absoluteString == base + "/app")
        #expect(JarvisService.chatURL(base: root, appStatus: 404).absoluteString == base + "/")
        // No answer at all: still the app; the browser shows why.
        #expect(JarvisService.chatURL(base: root, appStatus: nil).absoluteString == base + "/app")
    }
}
