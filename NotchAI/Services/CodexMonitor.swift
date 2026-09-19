import Foundation

/// Watches Codex (CLI and desktop app) by reading the session logs it writes to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Read-only.
@MainActor
final class CodexMonitor {
    static let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    static let recentWindow: TimeInterval = 30 * 60
    static let staleAfter: TimeInterval = 10 * 60

    var onEvent: ((AgentEvent, Date) -> Void)?
    private(set) var sessionDirectory: URL?

    private let follower: JSONLFollower

    init() {
        follower = JSONLFollower {
            // Today's and yesterday's folders are enough to find the active session.
            let calendar = Calendar.current
            return [Date.now, calendar.date(byAdding: .day, value: -1, to: .now) ?? .now].flatMap { day in
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let folder = Self.sessionsURL.appendingPathComponent(
                    String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
                return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "jsonl" }
            }
        }
        follower.onSwitch = { [weak self] url, lines in
            guard let self else { return }
            let fresh = Date.now.timeIntervalSince(JSONLFollower.modificationDate(url)) < Self.recentWindow
            self.replay(url: url, lines: fresh ? lines : [])
        }
        follower.onLines = { [weak self] lines in
            for entry in lines.compactMap(CodexLogParser.parse) {
                if let cwd = entry.cwd { self?.sessionDirectory = URL(fileURLWithPath: cwd) }
                if let event = entry.event { self?.onEvent?(event, entry.date) }
            }
        }
    }

    func poll() { follower.poll() }

    private func replay(url: URL, lines: [String]) {
        // The cwd is in the first line (session_meta), which the tail may not include.
        if let first = Self.firstLine(of: url), let cwd = CodexLogParser.parse(first)?.cwd {
            sessionDirectory = URL(fileURLWithPath: cwd)
        }
        let parsed = lines.compactMap(CodexLogParser.parse).filter { $0.event != nil }
        guard !parsed.isEmpty else {
            onEvent?(.interrupted, .now)
            return
        }
        let lastStart = parsed.lastIndex { entry in
            if case .promptSubmitted = entry.event { true } else { entry.isTaskStart }
        }
        for entry in parsed[(lastStart ?? max(0, parsed.count - 10))...] {
            if let event = entry.event { onEvent?(event, entry.date) }
        }
    }

    private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }
}

/// Codex session log lines (`~/.codex/sessions/.../rollout-*.jsonl`).
enum CodexLogParser {
    struct Entry {
        let event: AgentEvent?
        let date: Date
        let cwd: String?
        let isTaskStart: Bool
    }

    static func parse(_ line: String) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let date = (object["timestamp"] as? String).flatMap(ClaudeTranscriptParser.parseDate) ?? .now
        let payload = object["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String

        switch (object["type"] as? String, payloadType) {
        case ("session_meta", _), ("turn_context", _):
            return Entry(event: nil, date: date, cwd: payload["cwd"] as? String, isTaskStart: false)
        case ("event_msg", "task_started"):
            return Entry(event: .thinking, date: date, cwd: nil, isTaskStart: true)
        case ("event_msg", "task_complete"):
            let message = (payload["last_agent_message"] as? String).map { ClaudeTranscriptParser.summary($0) }
            return Entry(event: .completed(message), date: date, cwd: nil, isTaskStart: false)
        case ("event_msg", "turn_aborted"):
            return Entry(event: .interrupted, date: date, cwd: nil, isTaskStart: false)
        case ("event_msg", "error"), ("event_msg", "stream_error"):
            let message = (payload["message"] as? String).map { ClaudeTranscriptParser.summary($0) }
            return Entry(event: .failed(message ?? "Codex error"), date: date, cwd: nil, isTaskStart: false)
        case ("event_msg", let type?) where type.hasSuffix("approval_request"):
            return Entry(event: .approvalRequested("Codex needs approval"), date: date, cwd: nil, isTaskStart: false)
        case ("response_item", "message"):
            let role = payload["role"] as? String
            if role == "assistant" { return Entry(event: .thinking, date: date, cwd: nil, isTaskStart: false) }
            // Environment context and instructions are also "user" messages, wrapped in <tags>.
            guard role == "user", let text = text(in: payload), !text.hasPrefix("<") else { return nil }
            return Entry(event: .promptSubmitted(ClaudeTranscriptParser.summary(text)), date: date, cwd: nil, isTaskStart: false)
        case ("response_item", "reasoning"):
            return Entry(event: .thinking, date: date, cwd: nil, isTaskStart: false)
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            return Entry(event: .toolStarted(describeCall(payload)), date: date, cwd: nil, isTaskStart: false)
        case ("response_item", let type?) where type.hasSuffix("_output"):
            return Entry(event: .toolFinished, date: date, cwd: nil, isTaskStart: false)
        default:
            return nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func text(in payload: [String: Any]) -> String? {
        (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first
    }

    static func describeCall(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "tool"
        var command: String?
        if let input = payload["input"] as? String {
            command = input
        } else if let arguments = payload["arguments"] as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] {
            command = (object["command"] as? [String])?.last ?? object["command"] as? String ?? object["cmd"] as? String
        }
        // The desktop app wraps shell commands in a script: tools.exec_command({"cmd": "…"}).
        if let script = command, let cmd = firstMatch(#""cmd"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: script) {
            command = cmd.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if name == "apply_patch" || command?.hasPrefix("*** Begin Patch") == true
            || command?.contains("apply_patch") == true { return "Editing files" }
        if let command, ["exec", "shell", "exec_command", "local_shell"].contains(name) || payload["type"] as? String == "local_shell_call" {
            return "Running " + ClaudeTranscriptParser.summary(command, limit: 40)
        }
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// `codex exec --json` output (thread/turn/item events).
enum CodexExecParser {
    /// The event, plus the agent's latest message (used as the completion summary).
    static func parse(_ line: String) -> (event: AgentEvent?, message: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let item = object["item"] as? [String: Any] ?? [:]
        let itemType = item["type"] as? String

        switch type {
        case "turn.started":
            return (.thinking, nil)
        case "item.started":
            switch itemType {
            case "command_execution":
                return (.toolStarted("Running " + ClaudeTranscriptParser.summary(item["command"] as? String ?? "command", limit: 40)), nil)
            case "file_change": return (.toolStarted("Editing files"), nil)
            case "web_search": return (.toolStarted("Searching the web"), nil)
            case "mcp_tool_call": return (.toolStarted("Using " + (item["tool"] as? String ?? "tool")), nil)
            default: return (.thinking, nil)
            }
        case "item.completed":
            if itemType == "agent_message" {
                return (nil, (item["text"] as? String).map { ClaudeTranscriptParser.summary($0) })
            }
            return itemType == "command_execution" || itemType == "file_change" ? (.toolFinished, nil) : nil
        case "turn.completed":
            return (.completed(nil), nil)
        case "turn.failed":
            let error = (object["error"] as? [String: Any])?["message"] as? String
            return (.failed(ClaudeTranscriptParser.summary(error ?? "Codex failed")), nil)
        case "error":
            return (.failed(ClaudeTranscriptParser.summary(object["message"] as? String ?? "Codex error")), nil)
        default:
            return nil
        }
    }
}
