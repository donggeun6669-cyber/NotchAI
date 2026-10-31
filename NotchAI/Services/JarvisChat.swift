import Foundation
import Observation

// Talking to Jarvis from the notch (2026-11-01), through the same chat endpoints as its phone app
// (`jarvis/chat_api.py`): a conversation, a message whose answer streams back as server-sent
// events, the history, stop, and warm. Only what the server sends is shown: its streamed text,
// its real tool steps, its real jobs.

/// One event from a reply stream (`data: {"type": …}` lines).
enum JarvisChatEvent: Equatable {
    case accepted(userMessage: Int?, assistantMessage: Int?)
    /// A tool Jarvis is really using right now.
    case status(String)
    case delta(String)
    /// A job it handed to the team.
    case job(id: String, title: String?, status: String?)
    /// The finished answer; `status` is "done" or "stopped" when replayed.
    case done(text: String?, status: String?)
    case error(String)

    /// A `data:` line; nil for anything else (blank lines, comments, unknown event types).
    static func parse(line: String) -> JarvisChatEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "accepted":
            return .accepted(userMessage: (object["user_message_id"] as? NSNumber)?.intValue,
                             assistantMessage: (object["assistant_message_id"] as? NSNumber)?.intValue)
        case "status": return .status(object["text"] as? String ?? "")
        case "delta": return .delta(object["text"] as? String ?? "")
        case "job":
            guard let id = object["job_id"] as? String else { return nil }
            return .job(id: id, title: object["title"] as? String, status: object["status"] as? String)
        case "done": return .done(text: object["text"] as? String, status: object["status"] as? String)
        case "error":
            return .error(object["message"] as? String ?? object["status"] as? String ?? "오류")
        default: return nil
        }
    }
}

/// One bubble in the notch's chat.
struct JarvisChatLine: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    enum State: Equatable {
        case streaming
        case done
        case stopped
        case failed(String)
    }

    var id: String
    /// The server's message id, once known.
    var serverID: Int?
    var role: Role
    var text: String
    var state: State
    /// The tool step the server reported last, while the answer streams.
    var step: String?
    var jobIDs: [String] = []

    /// A saved message from `GET /api/conversations/{id}`.
    static func parse(message object: [String: Any]) -> JarvisChatLine? {
        guard let id = (object["id"] as? NSNumber)?.intValue,
              let role = object["role"] as? String, role == "user" || role == "assistant" else { return nil }
        let status = object["status"] as? String ?? "done"
        let state: State = switch status {
        case "done": .done
        case "stopped": .stopped
        case "streaming": .streaming
        default: .failed(object["error"] as? String ?? status)
        }
        return JarvisChatLine(id: "m\(id)", serverID: id, role: role == "user" ? .user : .assistant,
                              text: object["text"] as? String ?? "", state: role == "user" ? .done : state,
                              jobIDs: object["job_ids"] as? [String] ?? [])
    }
}

/// The notch's conversation with Jarvis. One conversation per day: questions asked from the notch
/// on the same day share their context, and a new day starts clean without piling up a new
/// conversation every time the app restarts. "새 대화" starts a fresh one at any time.
@MainActor
@Observable
final class JarvisChat {
    static let storeKey = "jarvisNotchConversation"
    static let historyLimit = 40
    /// History is fetched again when the panel opens after this long (the phone app may have
    /// added to the same conversation).
    static let refreshAfter: TimeInterval = 60

    private(set) var lines: [JarvisChatLine] = []
    private(set) var conversationID: String?
    /// An answer is streaming.
    private(set) var isAnswering = false
    /// Something the server said no to (busy, gone) or could not be reached for.
    private(set) var notice: String?
    var draft = ""

    @ObservationIgnored private let jarvis: JarvisService
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var lastLoad: Date?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var warmed: String?
    @ObservationIgnored private var askedAt: Date?

    /// A stop this soon after asking is the same click landing twice, not a decision.
    static let stopGrace: TimeInterval = 1.5

    init(jarvis: JarvisService, defaults: UserDefaults? = .standard) {
        self.jarvis = jarvis
        self.defaults = defaults
    }

    // MARK: Which conversation

    /// The stored "day|id" if it is today's.
    nonisolated static func reusable(stored: String?, today: String) -> String? {
        guard let stored, let bar = stored.firstIndex(of: "|"), stored[..<bar] == today else { return nil }
        let id = String(stored[stored.index(after: bar)...])
        return id.isEmpty ? nil : id
    }

    nonisolated static func day(_ date: Date = .now) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The panel opened: make sure today's conversation is loaded.
    func open(now: Date = .now) async {
        guard jarvis.presence != nil, !isAnswering else { return }
        if let lastLoad, now.timeIntervalSince(lastLoad) < Self.refreshAfter,
           conversationID == Self.reusable(stored: defaults?.string(forKey: Self.storeKey), today: Self.day(now)) {
            return
        }
        if let id = Self.reusable(stored: defaults?.string(forKey: Self.storeKey), today: Self.day(now)) {
            if await load(id, now: now) { return }
        }
        conversationID = nil
        lines = []
        lastLoad = now
    }

    /// Fetches a conversation's history. False when the server no longer has it.
    @discardableResult
    private func load(_ id: String, now: Date = .now) async -> Bool {
        guard let url = url("/api/conversations/\(id)?limit=\(Self.historyLimit)"),
              let (data, status) = try? await jarvis.transport.get(url) else { return false }
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        conversationID = id
        lines = (object["messages"] as? [[String: Any]] ?? []).compactMap(JarvisChatLine.parse(message:))
        lastLoad = now
        notice = nil
        // An answer still being written (asked from the phone, or before the notch closed): follow it.
        if let last = lines.last, last.role == .assistant, last.state == .streaming, let mid = last.serverID {
            follow(stream: "/api/conversations/\(id)/messages/\(mid)/stream", method: "GET", body: nil)
        }
        return true
    }

    /// Creates today's conversation on the server.
    private func create() async -> String? {
        let title = "노치 · " + Self.day()
        guard let url = url("/api/conversations"),
              let body = try? JSONSerialization.data(withJSONObject: ["title": title]),
              let (data, status) = try? await jarvis.transport.send("POST", url, json: body),
              status == 201 || status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { return nil }
        defaults?.set(Self.day() + "|" + id, forKey: Self.storeKey)
        conversationID = id
        return id
    }

    func newConversation() {
        guard !isAnswering else { return }
        defaults?.removeObject(forKey: Self.storeKey)
        conversationID = nil
        lines = []
        notice = nil
        warmed = nil
    }

    /// The text field got the keyboard: start Jarvis's brain while the question is typed.
    func warm() {
        guard let id = conversationID, warmed != id, let url = url("/api/conversations/\(id)/warm") else { return }
        warmed = id
        let transport = jarvis.transport
        Task { _ = try? await transport.send("POST", url, json: nil) }
    }

    // MARK: Asking

    /// Sends `question`, or the draft. The field hands over its own text on Return (the draft
    /// can be a keystroke behind it).
    func send(_ question: String? = nil) {
        let text = (question ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        draft = ""
        notice = nil
        isAnswering = true
        askedAt = .now
        lines.append(JarvisChatLine(id: UUID().uuidString, role: .user, text: text, state: .done))
        Task {
            var id = conversationID
            if id == nil { id = await create() }
            guard let id, let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
                fail("Jarvis에 닿지 않았습니다")
                return
            }
            follow(stream: "/api/conversations/\(id)/messages", method: "POST", body: body)
        }
    }

    /// Interrupts the answer. Ignored in the first moments after asking (2026-11-01: one click both
    /// sent a question and stopped it, 1 second apart).
    func stop(now: Date = .now) {
        if let askedAt, now.timeIntervalSince(askedAt) < Self.stopGrace { return }
        guard isAnswering, let id = conversationID, let url = url("/api/conversations/\(id)/stop") else { return }
        let transport = jarvis.transport
        Task { _ = try? await transport.send("POST", url, json: nil) }
    }

    private func follow(stream path: String, method: String, body: Data?) {
        guard let url = url(path) else { return }
        isAnswering = true
        if lines.last?.role != .assistant || lines.last?.state != .streaming {
            lines.append(JarvisChatLine(id: UUID().uuidString, role: .assistant, text: "", state: .streaming))
        }
        let transport = jarvis.transport
        streamTask = Task { [weak self] in
            do {
                let (status, stream) = try await transport.lines(method, url, json: body)
                guard status == 200 else {
                    var detail = ""
                    for try await line in stream { detail += line }
                    self?.rejected(status: status, body: detail)
                    return
                }
                for try await line in stream {
                    guard let event = JarvisChatEvent.parse(line: line) else { continue }
                    self?.apply(event)
                }
                self?.finishStream()
            } catch {
                self?.fail(JarvisOffline(error: error).explanation)
            }
        }
    }

    /// One event into the answer being written (always the last line).
    func apply(_ event: JarvisChatEvent) {
        guard let index = lines.indices.last, lines[index].role == .assistant else { return }
        switch event {
        case .accepted(let user, let assistant):
            lines[index].serverID = assistant
            if let user, let mine = lines.lastIndex(where: { $0.role == .user }) { lines[mine].serverID = user }
        case .status(let text):
            lines[index].step = text.isEmpty ? nil : text
        case .delta(let text):
            lines[index].text += text
            lines[index].step = nil
        case .job(let id, _, _):
            if !lines[index].jobIDs.contains(id) { lines[index].jobIDs.append(id) }
            jarvis.wantJobs()
        case .done(let text, let status):
            if let text, !text.isEmpty { lines[index].text = text }
            lines[index].state = status == "stopped" ? .stopped : .done
            lines[index].step = nil
            isAnswering = false
            jarvis.wantJobs()
        case .error(let message):
            lines[index].state = .failed(message)
            lines[index].step = nil
            isAnswering = false
        }
    }

    /// The stream ended without "done" (the connection closed): say so rather than leave it spinning.
    private func finishStream() {
        if let index = lines.indices.last, lines[index].state == .streaming {
            lines[index].state = .failed("답이 끊겼습니다")
            lines[index].step = nil
        }
        isAnswering = false
    }

    private func rejected(status: Int, body: String) {
        let detail = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["detail"] as? String
        if status == 404 {
            // The conversation is gone (another server, or deleted): the next question starts a new one.
            defaults?.removeObject(forKey: Self.storeKey)
            conversationID = nil
        }
        fail(detail ?? "Jarvis가 받지 않았습니다 (\(status))")
    }

    private func fail(_ message: String) {
        if let index = lines.indices.last, lines[index].role == .assistant, lines[index].state == .streaming {
            if lines[index].text.isEmpty { lines.remove(at: index) } else { lines[index].state = .failed(message) }
        }
        notice = message
        isAnswering = false
    }

    private func url(_ path: String) -> URL? {
        jarvis.baseURL.flatMap { URL(string: $0.absoluteString + path) }
    }
}
