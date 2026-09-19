import AppKit
import Foundation

/// Watches Claude Code by reading the session transcripts it already writes to
/// `~/.claude/projects/<project>/<session>.jsonl`. Read-only; nothing is installed for this.
///
/// Transcripts don't record permission prompts. For "waiting for approval" the user can opt in
/// to a Notification hook (see `ClaudeHookInstaller`); its events are read from `hookEventsURL`.
@MainActor
final class ClaudeCodeMonitor {
    static let projectsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// Sessions whose transcript is older than this are not replayed at startup.
    static let recentWindow: TimeInterval = 30 * 60
    /// A busy session that stops writing for this long is treated as ended.
    static let staleAfter: TimeInterval = 10 * 60

    var onEvent: ((AgentEvent, Date) -> Void)?
    /// Working directory of the session being followed.
    private(set) var sessionDirectory: URL?

    private let transcripts: JSONLFollower
    private let hookEvents: JSONLFollower

    init() {
        transcripts = JSONLFollower {
            let fm = FileManager.default
            let projects = (try? fm.contentsOfDirectory(at: Self.projectsURL, includingPropertiesForKeys: nil)) ?? []
            return projects.flatMap { dir in
                ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                    .filter { $0.pathExtension == "jsonl" }
            }
        }
        hookEvents = JSONLFollower { [ClaudeHookInstaller.eventsURL] }

        transcripts.onSwitch = { [weak self] url, lines in
            guard let self else { return }
            let fresh = Date.now.timeIntervalSince(JSONLFollower.modificationDate(url)) < Self.recentWindow
            self.replay(fresh ? lines : [])
        }
        transcripts.onLines = { [weak self] lines in self?.forward(lines) }

        hookEvents.onSwitch = { _, _ in }   // only events that arrive while running matter
        hookEvents.onLines = { [weak self] lines in
            for line in lines {
                if let message = ClaudeTranscriptParser.permissionPrompt(fromHookLine: line) {
                    self?.onEvent?(.approvalRequested(message), .now)
                }
            }
        }
    }

    func poll() {
        transcripts.poll()
        hookEvents.poll()
    }

    /// Re-derives the current state from the tail of a transcript: the last prompt, and the
    /// events after it.
    private func replay(_ lines: [String]) {
        let parsed = lines.compactMap(ClaudeTranscriptParser.parse)
        if let cwd = parsed.last(where: { $0.cwd != nil })?.cwd {
            sessionDirectory = URL(fileURLWithPath: cwd)
        }
        guard !parsed.isEmpty else {
            onEvent?(.interrupted, .now)
            return
        }
        // Long turns can push the prompt out of the tail; the last few events still give the state.
        let lastPrompt = parsed.lastIndex { if case .promptSubmitted = $0.event { true } else { false } }
        if lastPrompt == nil, let title = parsed.last(where: { if case .taskTitle = $0.event { true } else { false } }) {
            onEvent?(title.event, title.date)
        }
        for entry in parsed[(lastPrompt ?? max(0, parsed.count - 10))...] { onEvent?(entry.event, entry.date) }
    }

    private func forward(_ lines: [String]) {
        for entry in lines.compactMap(ClaudeTranscriptParser.parse) {
            if let cwd = entry.cwd { sessionDirectory = URL(fileURLWithPath: cwd) }
            onEvent?(entry.event, entry.date)
        }
    }
}

/// Translates Claude Code JSON lines (session transcripts and `claude -p --output-format stream-json`,
/// which use the same message shapes) into `AgentEvent`s.
enum ClaudeTranscriptParser {
    struct Entry {
        let event: AgentEvent
        let date: Date
        let cwd: String?
    }

    static func parse(_ line: String) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let date = (object["timestamp"] as? String).flatMap(parseDate) ?? .now
        let cwd = object["cwd"] as? String
        guard let event = event(from: object) else { return nil }
        return Entry(event: event, date: date, cwd: cwd)
    }

    private static func event(from object: [String: Any]) -> AgentEvent? {
        let type = object["type"] as? String
        if object["isSidechain"] as? Bool == true { return nil }   // subagent traffic

        if type == "result" {   // stream-json only: end of a `claude -p` run
            let text = (object["result"] as? String).map { summary($0) }
            return object["is_error"] as? Bool == true ? .failed(text ?? "Claude Code failed") : .completed(text)
        }

        let message = object["message"] as? [String: Any]
        if object["isApiErrorMessage"] as? Bool == true {
            return .failed(firstText(in: message).map { summary($0) } ?? "API error")
        }

        switch type {
        case "custom-title":
            return (object["customTitle"] as? String).map { .taskTitle(summary($0)) }
        case "last-prompt":
            return (object["lastPrompt"] as? String).map { .taskTitle(summary($0)) }

        case "attachment":
            // A message typed while Claude was already working.
            let attachment = object["attachment"] as? [String: Any]
            guard attachment?["type"] as? String == "queued_command",
                  let prompt = attachment?["prompt"] as? String else { return nil }
            return .promptSubmitted(summary(prompt))

        case "user":
            if object["isMeta"] as? Bool == true { return nil }
            let content = message?["content"]
            if let items = content as? [[String: Any]], items.contains(where: { $0["type"] as? String == "tool_result" }) {
                return .toolFinished
            }
            guard let text = (content as? String) ?? firstText(in: message) else { return nil }
            if text.hasPrefix("[Request interrupted") { return .interrupted }
            if text.hasPrefix("<") { return nil }   // slash-command output, reminders, etc.
            return .promptSubmitted(summary(text))

        case "assistant":
            let items = message?["content"] as? [[String: Any]] ?? []
            if let tool = items.last(where: { $0["type"] as? String == "tool_use" }) {
                return .toolStarted(describeTool(name: tool["name"] as? String ?? "Tool",
                                                 input: tool["input"] as? [String: Any] ?? [:]))
            }
            if message?["stop_reason"] as? String == "end_turn" {
                return .completed(firstText(in: message).map { summary($0) })
            }
            return .thinking

        default:
            return nil
        }
    }

    /// Hook input for a permission prompt (Notification hook), written by the opt-in hook script.
    static func permissionPrompt(fromHookLine line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let event = object["hook_event_name"] as? String
        let message = object["message"] as? String
        if event == "PermissionRequest" {
            return (object["tool_name"] as? String).map { "Allow \($0)?" } ?? "Permission needed"
        }
        guard event == "Notification" else { return nil }
        let kind = object["notification_type"] as? String
        if kind == "permission_prompt" || (kind == nil && message?.localizedCaseInsensitiveContains("permission") == true) {
            return message ?? "Permission needed"
        }
        return nil
    }

    static func describeTool(name: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        }
        switch name {
        case "Bash":
            if let description = input["description"] as? String { return summary(description) }
            return "Running " + summary(input["command"] as? String ?? "command", limit: 40)
        case "Read": return "Reading \(file())"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Grep", "Glob": return "Searching files"
        case "WebFetch", "WebSearch": return "Browsing the web"
        case "Agent", "Task": return "Agent: " + summary(input["description"] as? String ?? "subtask", limit: 40)
        case "TodoWrite": return "Updating plan"
        default:
            if name.hasPrefix("mcp__") {
                return "Using " + (name.split(separator: "_").last.map(String.init) ?? name)
            }
            return name
        }
    }

    private static func firstText(in message: [String: Any]?) -> String? {
        (message?["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "text" }?["text"] as? String
    }

    /// First line, shortened for the notch.
    static func summary(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Opt-in: adds a Notification hook to `~/.claude/settings.json` so permission prompts reach
/// the notch. Only runs after the user confirms a dialog showing exactly what will be added,
/// and backs the file up first.
@MainActor
enum ClaudeHookInstaller {
    static let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchAI")
    static let eventsURL = supportURL.appendingPathComponent("claude-events.jsonl")
    static let scriptURL = supportURL.appendingPathComponent("claude-hook.sh")
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    static let script = """
    #!/bin/sh
    # NotchAI: records Claude Code notifications (e.g. permission prompts) so the notch can show
    # "waiting for approval". Reads the hook JSON from stdin and appends it as one line. No network.
    dir="$HOME/Library/Application Support/NotchAI"
    mkdir -p "$dir"
    { tr -d '\\n'; echo; } >> "$dir/claude-events.jsonl"
    exit 0
    """

    static var hookCommand: String { "\"\(scriptURL.path)\"" }

    static var hookEntry: [String: Any] {
        ["hooks": [["type": "command", "command": hookCommand, "timeout": 5]]]
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("NotchAI/claude-hook.sh")
    }

    /// Shows what will change and installs only if the user agrees.
    static func askAndInstall() {
        let snippet = """
        "hooks": {
          "Notification": [
            { "hooks": [ { "type": "command",
                           "command": "\(scriptURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))",
                           "timeout": 5 } ] }
          ]
        }
        """
        let alert = NSAlert()
        alert.messageText = "Claude Code 승인 알림 켜기"
        alert.informativeText = """
        Claude Code가 권한을 물을 때 노치에 "Approve?"를 띄우려면 ~/.claude/settings.json에 아래 훅을 추가해야 합니다. 기존 훅은 그대로 두고, 먼저 백업본을 만듭니다.

        \(snippet)

        훅 스크립트는 알림 내용을 ~/Library/Application Support/NotchAI/claude-events.jsonl에 한 줄씩 적기만 합니다. 네트워크를 쓰지 않습니다.
        """
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try install()
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }

    private static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            settings = object
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            try data.write(to: settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.notchai-backup-\(stamp)"))
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var notification = hooks["Notification"] as? [Any] ?? []
        notification.append(hookEntry)
        hooks["Notification"] = notification
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
