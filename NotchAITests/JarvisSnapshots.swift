import AppKit
import SwiftUI
import Testing
@testable import NotchAI

/// Pictures of the 결재 panel, drawn off-screen (no window on the live desktop). Runs only when
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

    private static let diff = (["diff --git a/calc.py b/calc.py", "index 1535cd6..bfe0111 100644", "--- a/calc.py", "+++ b/calc.py",
                                "@@ -3,3 +3,7 @@", " ", " def add(a, b):", "     return a + b", "+", "+", "+def multiply(a, b):",
                                "+    return a * b"]).joined(separator: "\\n")

    private static let code = """
    {"id":"c1","kind":"code_change","team":"dev","status":"pending","status_ko":"결재 대기","title":"calc에 곱하기 함수 추가",
     "summary":"demo · 파일 2개 · 테스트 통과","created_at":\(Date().timeIntervalSince1970 - 600),
     "payload":{"repo":"/home/round/sandbox-test/demo","base_branch":"main","branch":"jarvis/20261101-035247","files":["M\\tcalc.py","M\\ttest_calc.py"],
      "diff":"\(diff)","diff_truncated":false,"remote":null,
      "tests":[{"command":"python3 -m unittest -v","ok":true},{"command":"python3 -m unittest -v","ok":true}]}}
    """

    private static let mail = """
    {"id":"m1","kind":"mail_draft","team":"secretary","status":"pending","status_ko":"결재 대기","title":"발표 자료 보내드립니다",
     "summary":"받는 사람 prof@example.ac.kr","created_at":\(Date().timeIntervalSince1970 - 3600),
     "payload":{"to":["prof@example.ac.kr"],"subject":"발표 자료 보내드립니다",
      "preview":"교수님 안녕하세요. 정동근입니다. 이번 주 발표 자료를 첨부합니다. 검토 부탁드립니다.",
      "location":"Gmail 임시보관함","view_url":"https://mail.google.com/mail/u/0/#drafts"}}
    """

    private func shoot<V: View>(_ view: V, _ name: String, size: CGSize, dark: Bool, in folder: URL) async throws {
        try await Task.sleep(for: .milliseconds(300))
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    @Test func approvalPanel() async throws {
        guard let folder = Self.folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = SnapshotServer([
            "GET /approvals?status=pending": (200, "[\(Self.code),\(Self.mail)]"),
            "GET /approvals/c1": (200, Self.code),
        ])
        let approvals = JarvisApprovals(jarvis: JarvisService(transport: server, address: "https://desk.example.ts.net"))
        approvals.undoDelay = .seconds(60)
        await approvals.refresh()
        await approvals.loadDetail("c1")
        func size() -> CGSize {
            let measure = NSHostingView(rootView: ApprovalSidePanel(approvals: approvals, scrolls: false))
            measure.layoutSubtreeIfNeeded()
            return measure.fittingSize
        }

        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            try await shoot(ApprovalSidePanel(approvals: approvals), "1-cards-\(tag)", size: size(), dark: dark, in: folder)
            approvals.toggleDiff("c1")
            try await Task.sleep(for: .milliseconds(200))
            try await shoot(ApprovalSidePanel(approvals: approvals), "2-diff-open-\(tag)", size: size(), dark: dark, in: folder)
            approvals.toggleDiff("c1")
        }
        approvals.reject("m1")
        try await shoot(ApprovalSidePanel(approvals: approvals), "3-reject-undo-light", size: size(), dark: false, in: folder)
        approvals.undoReject("m1")
        await server.set("POST /approvals/c1/approve", 200, Self.code.replacingOccurrences(
            of: #""status":"pending","status_ko":"결재 대기""#,
            with: #""status":"applied","status_ko":"반영됨","outcome":{"merged":true,"method":"fast-forward","push":"원격 저장소가 없어 push 하지 않았어요."}"#))
        await approvals.approve("c1")
        try await shoot(ApprovalSidePanel(approvals: approvals), "4-approved-light", size: size(), dark: false, in: folder)

        // The pill beside the closed notch, on the notch's black.
        let pill = HStack(spacing: 5) {
            ApprovalPill(pill: .init(count: 2, kind: "코드")) {}
            Circle().fill(JarvisOrbView.blue).frame(width: 8, height: 8)
                .overlay(alignment: .topTrailing) { Circle().fill(StudioTheme.red).frame(width: 5, height: 5).offset(x: 2, y: -2) }
        }
        .frame(width: 140, height: 32)
        .background(Color.black)
        try await shoot(pill, "5-pill", size: CGSize(width: 140, height: 32), dark: true, in: folder)
    }
}
