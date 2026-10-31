import Foundation
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
        #expect(item.approveConsequence.contains("demo의 main"))
        #expect(item.approveConsequence.contains("push는 하지 않습니다"))
    }

    @Test func aMailDraftWithFieldsThisBuildDoesNotKnow() throws {
        let item = try #require(JarvisApproval.parse(item: Data(mailItem.utf8)))
        let mail = try #require(item.mail)
        #expect(item.kindWord == "메일 초안")
        #expect(mail.to == ["prof@example.ac.kr"] && mail.subject == "발표 자료 보내드립니다")
        #expect(mail.location == "Gmail 임시보관함" && mail.viewURL != nil)
        #expect(item.approveConsequence.contains("보내지 않습니다"))
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
    private func make(_ server: FakeApprovals) -> JarvisApprovals {
        JarvisApprovals(jarvis: JarvisService(transport: server, address: base))
    }

    @Test func approvingShowsWhatTheServerDid() async throws {
        let id = "a20261101-034536-19d469"
        let server = FakeApprovals(["GET /approvals/\(id)": (200, codeItem)])
        await server.set("POST /approvals/\(id)/approve", 200, decided(codeItem, status: "applied", word: "반영됨",
                         outcome: #"{"merged":true,"method":"fast-forward","push":"원격 저장소가 없어 push 하지 않았어요."}"#))
        let approvals = make(server)
        await approvals.show(id)
        #expect(approvals.selected?.code?.diff != nil)

        approvals.note = "  시험이라 괜찮음 "
        approvals.ask(.approve, now: Date(timeIntervalSinceNow: -5))
        #expect(approvals.step == .confirming(.approve))
        await approvals.send(.approve, item: id, note: "시험이라 괜찮음")
        #expect(approvals.selected?.statusWord == "반영됨")
        #expect(approvals.selected?.outcome.first == "합쳤습니다 (fast-forward)")
        #expect(approvals.step == .reading)
        #expect(await server.bodies["POST /approvals/\(id)/approve"] == #"{"note":"시험이라 괜찮음"}"#)
    }

    @Test func oneTapNeverDecides() async {
        let server = FakeApprovals(["GET /approvals/m1": (200, mailItem)])
        let approvals = make(server)
        await approvals.show("m1")
        approvals.ask(.approve)
        approvals.confirm()   // the same click arriving again
        #expect(approvals.step == .confirming(.approve))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await !server.asked.contains("POST /approvals/m1/approve"))
        approvals.cancel()
        #expect(approvals.step == .reading)
    }

    @Test func alreadyDecidedShowsTheRealState() async {
        let server = FakeApprovals(["GET /approvals/m1": (200, mailItem)])
        let approvals = make(server)
        await approvals.show("m1")
        await server.set("POST /approvals/m1/reject", 409, #"{"detail":"이미 처리된 항목이에요 (확인함)"}"#)
        await server.set("GET /approvals/m1", 200, decided(mailItem, status: "approved", word: "확인함",
                         outcome: #"{"message":"확인함으로 기록했어요."}"#).replacingOccurrences(of: "\"future_field\"", with: "\"f\""))
        await approvals.send(.reject, item: "m1", note: nil)
        #expect(approvals.problem == "이미 처리된 항목이에요 (확인함)")
        #expect(approvals.selected?.statusWord == "확인함")
    }

    @Test func noAnswerIsNeverTakenForSuccess() async {
        let server = FakeApprovals(["GET /approvals/m1": (200, mailItem)])
        await server.fail("POST /approvals/m1/approve")
        let approvals = make(server)
        await approvals.show("m1")
        await approvals.send(.approve, item: "m1", note: nil)
        #expect(approvals.problem?.hasPrefix("결과를 받지 못했습니다") == true)
        #expect(approvals.selected?.isPending == true)   // re-read from the server: still waiting
    }

    @Test func theListIsOnlyWhatIsPending() async {
        let server = FakeApprovals(["GET /approvals?status=pending": (200, "[\(mailItem)]")])
        let approvals = make(server)
        approvals.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(approvals.isOpen && approvals.items.map(\.id) == ["m1"])
        approvals.close()
        #expect(!approvals.isOpen && approvals.selected == nil)
    }
}
