import AppKit
import SwiftUI
import Testing
@testable import NotchAI

/// Pictures of the 결재함 screens, drawn off-screen (no window on the live desktop). Runs only when
/// asked: `TEST_RUNNER_NOTCH_SNAPSHOT_DIR=<folder> scripts/run.sh test`.
private actor SnapshotServer: JarvisTransport {
    var answers: [String: (Int, String)]
    init(_ answers: [String: (Int, String)]) { self.answers = answers }
    func set(_ key: String, _ status: Int, _ body: String) { answers[key] = (status, body) }
    func get(_ url: URL) async throws -> (Data, Int) { try await send("GET", url, json: nil) }
    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int) {
        let key = "\(method) " + url.path + (url.query.map { "?" + $0 } ?? "")
        let (status, body) = answers[key] ?? (404, #"{"detail":"Not Found"}"#)
        return (Data(body.utf8), status)
    }
}

@MainActor
struct JarvisSnapshots {
    static let folder = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))

    private static let diff = (["diff --git a/notch/Recorder.swift b/notch/Recorder.swift", "index 1a2b3c4..5d6e7f8 100644",
                                "--- a/notch/Recorder.swift", "+++ b/notch/Recorder.swift", "@@ -40,7 +40,9 @@ final class Recorder {"]
        + (0..<50).map { $0 % 3 == 0 ? "+    let check\($0) = verify(level)" : ($0 % 3 == 1 ? "-    let old\($0) = level" : "     context line \($0)") })
        .joined(separator: "\\n")

    private static let code = """
    {"id":"c1","kind":"code_change","status":"pending","status_ko":"결재 대기","title":"코드 변경: 녹음 확인 강화",
     "summary":"NotchAI · 파일 2개 · 테스트 통과","created_at":\(Date().timeIntervalSince1970 - 600),
     "payload":{"repo":"/home/round/code/NotchAI","base_branch":"main","branch":"jarvis/20261101-0400","files":["M\\tnotch/Recorder.swift","A\\tnotch/RecorderCheck.swift"],
      "diff":"\(diff)","diff_truncated":false,"remote":"origin",
      "tests":[{"command":"swift test --filter Recorder","ok":true,"output_tail":"Executed 12 tests"},{"command":"swift test","ok":true}],
      "summary":"녹음 시작 3초 확인을 두 번으로 늘렸습니다. 기존 테스트는 모두 통과합니다."}}
    """

    private static let mail = """
    {"id":"m1","kind":"mail_draft","status":"pending","status_ko":"결재 대기","title":"메일 초안: 발표 자료 보내드립니다",
     "summary":"받는 사람 prof@example.ac.kr · Gmail 임시보관함","created_at":\(Date().timeIntervalSince1970 - 3600),
     "payload":{"to":["prof@example.ac.kr"],"cc":["team@example.ac.kr"],"subject":"발표 자료 보내드립니다",
      "preview":"교수님 안녕하세요. 정동근입니다. 이번 주 발표 자료를 첨부합니다. 검토 부탁드립니다. 감사합니다.",
      "location":"Gmail 임시보관함","view_url":"https://mail.google.com/mail/u/0/#drafts"}}
    """

    @Test func approvalScreens() async throws {
        guard let folder = Self.folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = SnapshotServer([
            "GET /presence": (200, #"{"state":"needs_approval","running_jobs":0,"queued_jobs":0,"approvals":2}"#),
            "GET /jobs?limit=3": (200, #"[{"id":"j1","title":"녹음 확인 강화","status":"done"},{"id":"j2","title":"발표 메일 초안","status":"done"}]"#),
            "GET /approvals?status=pending": (200, "[\(Self.code),\(Self.mail)]"),
            "GET /approvals/c1": (200, Self.code),
            "GET /approvals/m1": (200, Self.mail),
        ])
        let jarvis = JarvisService(transport: server, address: "https://desk.example.ts.net")
        await jarvis.pollOnce()
        await jarvis.refreshJobs()
        let chat = JarvisChat(jarvis: jarvis, defaults: nil)
        let approvals = JarvisApprovals(jarvis: jarvis)

        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(400))
            let view = JarvisPane(jarvis: jarvis, chat: chat, approvals: approvals)
                .padding(14)
                .frame(width: 430, height: 392, alignment: .top)
                .background(LinearGradient(colors: [.black, Color(nsColor: NotchPalette.nsGraphite)],
                                           startPoint: .top, endPoint: .bottom))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 430, height: 392)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }

        try await shoot("1-chat-with-approval-line")
        approvals.open()
        try await shoot("2-list")
        await approvals.show("c1")
        try await shoot("3-code-detail")
        approvals.ask(.approve, now: .distantPast)
        try await shoot("4-confirm")
        approvals.cancel()
        await server.set("POST /approvals/c1/approve", 200, Self.code
            .replacingOccurrences(of: #""status":"pending","status_ko":"결재 대기""#, with: #""status":"applied","status_ko":"반영됨","outcome":{"merged":true,"method":"fast-forward","push":"push 완료: main -> main"}"#))
        await approvals.send(.approve, item: "c1", note: nil)
        try await shoot("5-approved-result")
        await approvals.show("m1")
        try await shoot("6-mail-detail")
        await server.set("POST /approvals/m1/approve", 200, Self.mail.replacingOccurrences(of: #""status":"pending","status_ko":"결재 대기""#,
            with: #""status":"failed","status_ko":"반영 실패","outcome":{"merged":false,"error":"원본 폴더에 아직 커밋 안 된 변경이 있어서 합치지 않았어요."}"#))
        await approvals.send(.approve, item: "m1", note: nil)
        try await shoot("7-failed-result")
    }
}
