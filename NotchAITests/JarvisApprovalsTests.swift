import Foundation
import SwiftUI
import Testing
@testable import NotchAI

/// A 결재함 server: canned answers per "METHOD path"; records what was asked and with which body.
private actor FakeApprovals: JarvisTransport {
    var answers: [String: (Int, String)]
    var failing: Set<String> = []
    private(set) var asked: [String] = []
    private(set) var bodies: [String: String] = [:]

    init(_ answers: [String: (Int, String)]) { self.answers = answers }

    func set(_ key: String, _ status: Int, _ body: String) { answers[key] = (status, body) }
    func fail(_ key: String) { failing.insert(key) }

    func get(_ url: URL) async throws -> (Data, Int) { try await send("GET", url, json: nil) }

    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int) {
        let key = "\(method) " + url.path + (url.query.map { "?" + $0 } ?? "")
        asked.append(key)
        if let json { bodies[key] = String(decoding: json, as: UTF8.self) }
        if failing.contains(key) { throw URLError(.timedOut) }
        let (status, body) = answers[key] ?? (404, #"{"detail":"Not Found"}"#)
        return (Data(body.utf8), status)
    }
}

private let base = "https://desk.example.ts.net"

/// The pending item on the desktop on 2026-11-01 (the dev team's sandbox test), as `/approvals/{id}` sent it,
/// with the team's long report shortened.
private let codeItem = #"""
{"id":"a20261101-034536-19d469","kind":"code_change","team":"dev","job_id":"20261101-034511-b2bb81","status":"pending",
 "title":"코드 변경: 샌드박스 확인 3 (시험)","summary":"demo · 파일 1개 · 테스트 실행 기록 없음",
 "payload":{"repo":"/home/round/sandbox-test/demo","base_branch":"main","base_commit":"25f2508","branch":"jarvis/20261101-034511-b2bb81",
  "head_commit":"af0c0fe","worktree":"/home/round/.local/share/jarvis/worktrees/20261101-034511-b2bb81","files":["A\tprobe_inside.txt"],
  "diffstat":"probe_inside.txt | 1 +\n 1 file changed, 1 insertion(+)",
  "diff":"diff --git a/probe_inside.txt b/probe_inside.txt\nnew file mode 100644\nindex 0000000..5be24b7\n--- /dev/null\n+++ b/probe_inside.txt\n@@ -0,0 +1 @@\n+inside\n",
  "diff_truncated":false,"tests":[],"summary":"동근님, 점검 결과입니다.","remote":null,"session_id":"6fca9ea8","resume":{"terminal":"cd …"}},
 "note":null,"outcome":null,"created_at":1793472336.348591,"decided_at":null,"updated_at":1793472336.348591,"status_ko":"결재 대기"}
"""#

private let mailItem = #"""
{"id":"m1","kind":"mail_draft","team":"secretary","status":"pending","title":"메일 초안: 발표 자료 보내드립니다",
 "summary":"받는 사람 prof@example.ac.kr · Gmail 임시보관함","created_at":1793472000,"status_ko":"결재 대기",
 "payload":{"action":"create","ok":true,"to":["prof@example.ac.kr"],"cc":[],"bcc":[],"subject":"발표 자료 보내드립니다",
  "draft_id":"r-1","view_url":"https://mail.google.com/mail/u/0/#drafts","preview":"교수님 안녕하세요. 발표 자료를 첨부합니다.",
  "location":"Gmail 임시보관함","future_field":{"x":1}}}
"""#

private func decided(_ item: String, status: String, word: String, outcome: String) -> String {
    item.replacingOccurrences(of: #""status":"pending""#, with: "\"status\":\"\(status)\"")
        .replacingOccurrences(of: #""status_ko":"결재 대기""#, with: "\"status_ko\":\"\(word)\"")
        .replacingOccurrences(of: #""outcome":null"#, with: "\"outcome\":\(outcome)")
}

struct JarvisApprovalParsingTests {
    @Test func aRealCodeChange() throws {
        let item = try #require(JarvisApproval.parse(item: Data(codeItem.utf8)))
        #expect(item.isPending && item.kindWord == "코드 변경" && item.statusWord == "결재 대기")
        let code = try #require(item.code)
        #expect(code.repoName == "demo" && code.baseBranch == "main" && code.remote == nil)
        #expect(code.files == ["A\tprobe_inside.txt"])
        #expect(code.diff?.contains("+inside") == true)
        #expect(code.tests.isEmpty)
        #expect(item.consequence == "demo main에 합쳐요 · push 안 함")
        #expect(item.teamWord == "개발팀" && item.evidence == "파일 1개 · 테스트 기록 없음")
        #expect(item.needsHold && item.shortKind == "코드")
    }

    @Test func aMailDraftWithFieldsThisBuildDoesNotKnow() throws {
        let item = try #require(JarvisApproval.parse(item: Data(mailItem.utf8)))
        let mail = try #require(item.mail)
        #expect(item.kindWord == "메일 초안")
        #expect(mail.to == ["prof@example.ac.kr"] && mail.subject == "발표 자료 보내드립니다")
        #expect(mail.location == "Gmail 임시보관함" && mail.viewURL != nil)
        #expect(item.consequence == "받는 사람 prof@example.ac.kr · 보내기는 Gmail에서 직접")
        #expect(!item.needsHold && item.teamWord == "비서실" && item.shortKind == "메일")
    }

    @Test func outcomesAreSaidAsTheServerSaidThem() throws {
        let applied = try #require(JarvisApproval.parse(item: Data(decided(codeItem, status: "applied", word: "반영됨",
            outcome: #"{"merged":true,"pushed":false,"method":"fast-forward","push":"원격 저장소가 없어 push 하지 않았어요."}"#).utf8)))
        #expect(applied.outcome == ["합쳤습니다 (fast-forward)", "원격 저장소가 없어 push 하지 않았어요."])
        #expect(!applied.isPending && !applied.didFail)

        let failed = try #require(JarvisApproval.parse(item: Data(decided(codeItem, status: "failed", word: "반영 실패",
            outcome: #"{"merged":false,"pushed":false,"error":"원본 폴더에 아직 커밋 안 된 변경이 있어서 합치지 않았어요."}"#).utf8)))
        #expect(failed.didFail)
        #expect(failed.outcome == ["원본 폴더에 아직 커밋 안 된 변경이 있어서 합치지 않았어요."])
    }

    @Test func aListWithoutDiffs() throws {
        let list = try #require(JarvisApproval.parse(list: Data("[\(mailItem),{\"id\":\"x\"}]".utf8)))
        #expect(list.map(\.id) == ["m1", "x"])
        #expect(list[1].kindWord == "" && list[1].title == "x")
    }
}

@MainActor
struct JarvisApprovalFlowTests {
    private let codeID = "a20261101-034536-19d469"

    private func make(_ server: FakeApprovals) -> JarvisApprovals {
        let approvals = JarvisApprovals(jarvis: JarvisService(transport: server, address: base))
        approvals.undoDelay = .milliseconds(150)
        return approvals
    }

    private func pause(_ ms: Int = 350) async { try? await Task.sleep(for: .milliseconds(ms)) }

    @Test func holdToApproveShowsWhatTheServerDid() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(codeItem)]")])
        await server.set("POST /approvals/\(codeID)/approve", 200, decided(codeItem, status: "applied", word: "반영됨",
                         outcome: #"{"merged":true,"method":"fast-forward","push":"원격 저장소가 없어 push 하지 않았어요."}"#))
        let approvals = make(server)
        await approvals.refresh()
        approvals.notes[codeID] = "  시험이라 괜찮음 "
        await approvals.approve(codeID)
        #expect(approvals.results[codeID]?.statusWord == "반영됨")
        #expect(approvals.results[codeID]?.outcome.first == "합쳤습니다 (fast-forward)")
        #expect(await server.bodies["POST /approvals/\(codeID)/approve"] == #"{"note":"시험이라 괜찮음"}"#)
        #expect(approvals.cards.first?.id == codeID)   // the card stays, with its result
        approvals.closeResult(codeID)
        #expect(approvals.results.isEmpty)
    }

    @Test func rejectHidesAtOnceAndUndoSendsNothing() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]")])
        let approvals = make(server)
        await approvals.refresh()
        approvals.reject("m1")
        #expect(approvals.cards.isEmpty)
        #expect(approvals.pendingRejects.map(\.id) == ["m1"])
        approvals.undoReject("m1")
        #expect(approvals.cards.map(\.id) == ["m1"])
        await pause()
        #expect(await !server.asked.contains("POST /approvals/m1/reject"))
    }

    @Test func rejectIsSentWhenTheCountEnds() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]")])
        await server.set("POST /approvals/m1/reject", 200, mailItem.replacingOccurrences(
            of: #""status":"pending""#, with: #""status":"rejected","outcome":{"message":"반려 기록만 했어요."}"#))
        let approvals = make(server)
        await approvals.refresh()
        approvals.reject("m1")
        #expect(await !server.asked.contains("POST /approvals/m1/reject"))
        await pause()
        #expect(await server.asked.contains("POST /approvals/m1/reject"))
        #expect(approvals.rejectNotice == "반려됐어요 · 반려 기록만 했어요.")
        #expect(approvals.pendingRejects.isEmpty)
    }

    /// The app quits inside the five seconds: nothing was sent, the item stays waiting.
    @Test func quittingBeforeTheCountEndsSendsNothing() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]")])
        var approvals: JarvisApprovals? = make(server)
        await approvals?.refresh()
        approvals?.reject("m1")
        approvals = nil
        await pause()
        #expect(await !server.asked.contains("POST /approvals/m1/reject"))
    }

    @Test func alreadyDecidedShowsTheRealState() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]"),
                                    "POST /approvals/m1/approve": (409, #"{"detail":"이미 처리된 항목이에요 (반려)"}"#),
                                    "GET /approvals/m1": (200, decided(mailItem, status: "rejected", word: "반려",
                                                                      outcome: #"{"message":"반려 기록만 했어요."}"#))])
        let approvals = make(server)
        await approvals.refresh()
        await approvals.approve("m1")
        #expect(approvals.problems["m1"] == "이미 처리된 항목이에요 (반려)")
        #expect(approvals.results["m1"]?.statusWord == "반려")
    }

    @Test func noAnswerIsNeverTakenForSuccess() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]"),
                                    "GET /approvals/m1": (200, mailItem)])
        await server.fail("POST /approvals/m1/approve")
        let approvals = make(server)
        await approvals.refresh()
        await approvals.approve("m1")
        #expect(approvals.problems["m1"]?.hasPrefix("결과를 받지 못했어요") == true)
        #expect(approvals.results["m1"] == nil)            // still pending on the server
        #expect(approvals.cards.map(\.id) == ["m1"])
    }

    /// 「보기를 눌러야 옆 패널에 뜨는걸로」 (6차): waiting items alone never bring the panel up.
    @Test func thePanelIsUpOnlyAfterLooking() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[]")])
        let approvals = make(server)
        await approvals.refresh()
        approvals.open()
        await pause(100)
        #expect(!approvals.wantsPanel)   // nothing waiting: never an empty panel

        await server.set("GET /approvals?status=pending", 200, "[\(mailItem)]")
        approvals.dismiss()
        await approvals.refresh(announcing: true)
        #expect(!approvals.wantsPanel)   // something waits, but 「보기」 was not pressed
        #expect(approvals.pill == JarvisApprovals.Pill(count: 1, kind: "메일"))

        approvals.open()
        await pause(100)
        #expect(approvals.wantsPanel)
        #expect(approvals.pill == nil)   // looked at: the pill has done its job
        approvals.dismiss()              // ✕ or the notch closing
        #expect(!approvals.wantsPanel)
    }

    @Test func theFirstReadAnnouncesNothing() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]")])
        let approvals = make(server)
        await approvals.refresh(announcing: true)
        #expect(approvals.pill == nil)   // already waiting when the app started: the red dot says it
    }

    @Test func thePillGoesAwayByItself() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[]")])
        let approvals = make(server)
        approvals.pillDuration = .milliseconds(100)
        await approvals.refresh()
        await server.set("GET /approvals?status=pending", 200, "[\(mailItem)]")
        await approvals.refresh(announcing: true)
        #expect(approvals.pill != nil)
        await pause(300)
        #expect(approvals.pill == nil)
    }
}

struct SideFrameTests {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let size = CGSize(width: 220, height: 300)

    /// 「노치 기본적으로 왼쪽에」 (6차).
    @Test func leftOfTheNotchOnTheBuiltInScreen() {
        let panel = CGRect(x: 406, y: 982 - 424, width: 700, height: 424)
        let frame = NotchGeometry.sideFrame(beside: panel, in: builtIn, size: size, top: 944)
        #expect(frame == CGRect(x: 176, y: 644, width: 220, height: 300))
    }

    @Test func rightWhenTheLeftHasNoRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1300, height: 900)
        let panel = CGRect(x: 100, y: 476, width: 700, height: 424)
        let frame = NotchGeometry.sideFrame(beside: panel, in: screen, size: size, top: 870)
        #expect(frame.minX == 810)
    }

    @Test func underThePanelOnAPortraitScreen() {
        let portrait = CGRect(x: 1512, y: -500, width: 1080, height: 1920)
        let panel = CGRect(x: 1702, y: 1420 - 424, width: 700, height: 424)
        let frame = NotchGeometry.sideFrame(beside: panel, in: portrait, size: CGSize(width: 220, height: 300), top: 1390)
        #expect(frame.maxY == panel.minY - 10)
        #expect(frame.minX >= portrait.minX && frame.maxX <= portrait.maxX)
    }
}

@MainActor
struct PanelHeightTests {
    /// The panel's height comes from its cards: one card is short, two are taller, and an open diff
    /// taller still. 6차: the panel showed only its title because its height never arrived.
    @Test func theMeasuredHeightFollowsTheCards() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(codeItem)]"),
                                    "GET /approvals/\("a20261101-034536-19d469")": (200, codeItem)])
        let approvals = JarvisApprovals(jarvis: JarvisService(transport: server, address: base))
        await approvals.refresh()
        func height() -> CGFloat {
            let hosting = NSHostingView(rootView: ApprovalSidePanel(approvals: approvals, scrolls: false))
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        let one = height()
        #expect(one > 150)
        #expect(one < 330)
        await server.set("GET /approvals?status=pending", 200, "[\(codeItem),\(mailItem)]")
        await approvals.refresh()
        let two = height()
        #expect(two > one + 100)
        approvals.toggleDiff("a20261101-034536-19d469")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(height() > two)
    }
}
