import Foundation
import Testing
@testable import NotchAI

/// A Jarvis server for the chat: canned answers per "METHOD path", event streams as lines.
private actor FakeChatServer: JarvisTransport {
    var answers: [String: (Int, String)]
    var streams: [String: (Int, [String])]
    private(set) var asked: [String] = []

    init(answers: [String: (Int, String)] = [:], streams: [String: (Int, [String])] = [:]) {
        self.answers = answers
        self.streams = streams
    }

    private static func key(_ method: String, _ url: URL) -> String {
        "\(method) " + url.path + (url.query.map { "?" + $0 } ?? "")
    }

    func get(_ url: URL) async throws -> (Data, Int) {
        try await send("GET", url, json: nil)
    }

    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int) {
        let key = Self.key(method, url)
        asked.append(key)
        guard let (status, body) = answers[key] else { return (Data(#"{"detail":"Not Found"}"#.utf8), 404) }
        return (Data(body.utf8), status)
    }

    func lines(_ method: String, _ url: URL, json: Data?) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let key = Self.key(method, url)
        asked.append(key)
        let (status, lines) = streams[key] ?? (404, [#"{"detail":"없는 대화"}"#])
        return (status, AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        })
    }
}

private let base = "https://desk.example.ts.net"
private let online = #"{"state":"idle","running_jobs":0,"queued_jobs":0,"approvals":0}"#

struct JarvisChatParsingTests {
    @Test func everyEventTheServerSends() {
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"accepted","user_message_id":7,"assistant_message_id":8}"#)
                == .accepted(userMessage: 7, assistantMessage: 8))
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"status","text":"DEAN 파일 읽는 중"}"#) == .status("DEAN 파일 읽는 중"))
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"delta","text":"내일 "}"#) == .delta("내일 "))
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"job","job_id":"j1","title":"정리","status":"queued"}"#)
                == .job(id: "j1", title: "정리", status: "queued"))
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"done","text":"끝","timings":{"total_s":1.2}}"#)
                == .done(text: "끝", status: nil))
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"error","message":"두뇌가 멈췄어요"}"#) == .error("두뇌가 멈췄어요"))
    }

    @Test func unknownAndNonDataLinesAreSkipped() {
        #expect(JarvisChatEvent.parse(line: "") == nil)
        #expect(JarvisChatEvent.parse(line: ": keep-alive") == nil)
        #expect(JarvisChatEvent.parse(line: #"data: {"type":"approval","id":3}"#) == nil)   // a future event
        #expect(JarvisChatEvent.parse(line: "data: not json") == nil)
    }

    @Test func savedMessages() throws {
        let done = try #require(JarvisChatLine.parse(message: ["id": 4, "role": "assistant", "text": "네", "status": "done",
                                                              "job_ids": ["j1"], "extra_field": true]))
        #expect(done.state == .done && done.jobIDs == ["j1"] && done.serverID == 4)
        let broken = try #require(JarvisChatLine.parse(message: ["id": 5, "role": "assistant", "text": "",
                                                                "status": "interrupted", "error": "재시작"]))
        #expect(broken.state == .failed("재시작"))
        #expect(JarvisChatLine.parse(message: ["id": 6, "role": "system", "text": "x"]) == nil)
    }

    @Test func oneConversationPerDay() {
        #expect(JarvisChat.reusable(stored: "2026-11-01|c1", today: "2026-11-01") == "c1")
        #expect(JarvisChat.reusable(stored: "2026-10-31|c1", today: "2026-11-01") == nil)
        #expect(JarvisChat.reusable(stored: nil, today: "2026-11-01") == nil)
        #expect(JarvisChat.reusable(stored: "garbage", today: "2026-11-01") == nil)
    }
}

@MainActor
struct JarvisChatTests {
    private func make(_ server: FakeChatServer) async -> (JarvisService, JarvisChat, UserDefaults, String) {
        let suite = "JarvisChatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let jarvis = JarvisService(transport: server, address: base)
        await jarvis.pollOnce()
        return (jarvis, JarvisChat(jarvis: jarvis, defaults: defaults), defaults, suite)
    }

    private func waitUntilAnswered(_ chat: JarvisChat) async throws {
        for _ in 0..<100 where chat.isAnswering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!chat.isAnswering)
    }

    @Test func firstQuestionOfTheDayStartsAConversationAndStreams() async throws {
        let server = FakeChatServer(
            answers: ["GET /presence": (200, online), "POST /api/conversations": (201, #"{"id":"c9","title":"노치"}"#)],
            streams: ["POST /api/conversations/c9/messages": (200, [
                #"data: {"type":"accepted","user_message_id":1,"assistant_message_id":2}"#, "",
                #"data: {"type":"status","text":"일정 보는 중"}"#, "",
                #"data: {"type":"delta","text":"내일 "}"#, "",
                #"data: {"type":"delta","text":"9시예요"}"#, "",
                #"data: {"type":"job","job_id":"j1","title":"정리","status":"queued"}"#, "",
                #"data: {"type":"done","text":"내일 9시예요.","timings":{}}"#, ""])])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }

        chat.draft = "내일 첫 수업?"
        chat.send()
        #expect(chat.draft.isEmpty)
        try await waitUntilAnswered(chat)
        #expect(chat.lines.map(\.role) == [.user, .assistant])
        #expect(chat.lines[1].text == "내일 9시예요.")
        #expect(chat.lines[1].state == .done)
        #expect(chat.lines[1].jobIDs == ["j1"])
        #expect(chat.lines[1].serverID == 2)
        #expect(chat.conversationID == "c9")
        #expect(JarvisChat.reusable(stored: defaults.string(forKey: JarvisChat.storeKey), today: JarvisChat.day()) == "c9")
    }

    /// The stream exactly as the desktop's Jarvis sent it on 2026-11-01 (curl, blank lines included).
    @Test func aRealReplyFromTheServer() async throws {
        let server = FakeChatServer(
            answers: ["GET /presence": (200, online), "POST /api/conversations": (201, #"{"id":"c2"}"#)],
            streams: ["POST /api/conversations/c2/messages": (200, [
                #"data: {"type": "accepted", "user_message_id": 41, "assistant_message_id": 42, "received_at": 1793471800.3464243, "model": "sonnet"}"#,
                #""#,
                #"data: {"type": "delta", "text": "노"}"#,
                #""#,
                #"data: {"type": "delta", "text": "치 연결은"}"#,
                #""#,
                #"data: {"type": "delta", "text": " 잘 되고"}"#,
                #""#,
                #"data: {"type": "delta", "text": " 있어요, 동"}"#,
                #""#,
                #"data: {"type": "delta", "text": "근님."}"#,
                #""#,
                #"data: {"type": "done", "status": "done", "text": "노치 연결은 잘 되고 있어요, 동근님.", "tools": [], "timings": {"cold": false, "first_token_s": 1.112, "total_s": 1.735, "brain_s": 1.728}}"#,
                #""#])])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }
        chat.send("노치 연결 시험이에요. 한 문장으로 짧게 답해 주세요.")
        try await waitUntilAnswered(chat)
        #expect(chat.lines.last?.text == "노치 연결은 잘 되고 있어요, 동근님.")
        #expect(chat.lines.last?.state == .done)
        #expect(chat.lines.last?.serverID == 42)
    }

    @Test func todaysConversationIsReloaded() async throws {
        let history = #"{"id":"c9","messages":[{"id":1,"role":"user","text":"안녕","status":"done"},{"id":2,"role":"assistant","text":"안녕하세요","status":"done","job_ids":[]}]}"#
        let server = FakeChatServer(answers: ["GET /presence": (200, online),
                                              "GET /api/conversations/c9?limit=\(JarvisChat.historyLimit)": (200, history)])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(JarvisChat.day() + "|c9", forKey: JarvisChat.storeKey)

        await chat.open()
        #expect(chat.conversationID == "c9")
        #expect(chat.lines.map(\.text) == ["안녕", "안녕하세요"])
    }

    @Test func yesterdaysConversationIsNotReused() async {
        let server = FakeChatServer(answers: ["GET /presence": (200, online)])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("2000-01-01|old", forKey: JarvisChat.storeKey)

        await chat.open()
        #expect(chat.conversationID == nil)
        #expect(chat.lines.isEmpty)
        #expect(await !server.asked.contains { $0.contains("old") })
    }

    @Test func busyIsSaidPlainly() async throws {
        let server = FakeChatServer(
            answers: ["GET /presence": (200, online)],
            streams: ["POST /api/conversations/c9/messages": (409, [#"{"detail":"아직 앞의 질문에 답하는 중이에요"}"#])])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(JarvisChat.day() + "|c9", forKey: JarvisChat.storeKey)
        let history = #"{"id":"c9","messages":[]}"#
        await server.setAnswer("GET /api/conversations/c9?limit=\(JarvisChat.historyLimit)", 200, history)
        await chat.open()

        chat.draft = "또 질문"
        chat.send()
        try await waitUntilAnswered(chat)
        #expect(chat.notice == "아직 앞의 질문에 답하는 중이에요")
        #expect(chat.lines.map(\.role) == [.user])   // no empty answer left behind
    }

    @Test func aStreamThatEndsWithoutDoneIsMarked() async throws {
        let server = FakeChatServer(
            answers: ["GET /presence": (200, online), "POST /api/conversations": (201, #"{"id":"c1"}"#)],
            streams: ["POST /api/conversations/c1/messages": (200, [#"data: {"type":"delta","text":"반쯤"}"#])])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }
        chat.draft = "길게 설명해줘"
        chat.send()
        try await waitUntilAnswered(chat)
        #expect(chat.lines.last?.text == "반쯤")
        #expect(chat.lines.last?.state == .failed("답이 끊겼습니다"))
    }

    @Test func aStoppedAnswerKeepsWhatWasWritten() async throws {
        let server = FakeChatServer(
            answers: ["GET /presence": (200, online), "POST /api/conversations": (201, #"{"id":"c1"}"#)],
            streams: ["POST /api/conversations/c1/messages": (200, [
                #"data: {"type":"status","text":"웹 검색 중"}"#,
                #"data: {"type":"delta","text":"찾았어요"}"#,
                #"data: {"type":"done","status":"stopped"}"#])])
        let (_, chat, defaults, suite) = await make(server)
        defer { defaults.removePersistentDomain(forName: suite) }
        chat.draft = "찾아줘"
        chat.send()
        try await waitUntilAnswered(chat)
        #expect(chat.lines.last?.text == "찾았어요")
        #expect(chat.lines.last?.state == .stopped)
        #expect(chat.lines.last?.step == nil)
    }
}

extension FakeChatServer {
    func setAnswer(_ key: String, _ status: Int, _ body: String) { answers[key] = (status, body) }
}
