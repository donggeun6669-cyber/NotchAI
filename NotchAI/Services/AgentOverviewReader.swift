import Darwin
import Foundation

/// Reads the session lists and usage that Claude Code and Codex keep on disk. Read-only.
enum AgentOverviewReader {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Claude

    /// `~/.claude/sessions/<pid>.json`: one file per running Claude Code session (CLI or desktop),
    /// with its name and whether it is busy. Files of processes that have exited are skipped.
    static func claudeSessions(isAlive: (Int32) -> Bool = processIsAlive) -> [AgentOverview.Session] {
        let folder = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return claudeSession(from: data, isAlive: isAlive)
        }
    }

    static func claudeSession(from data: Data, isAlive: (Int32) -> Bool) -> AgentOverview.Session? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, isAlive(pid),
              let id = object["sessionId"] as? String else { return nil }
        // One-off `claude -p` runs (including the notch's own) are not sessions the user keeps open.
        if object["kind"] as? String == "print" { return nil }
        let cwd = object["cwd"] as? String
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
        let updated = (object["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
        return AgentOverview.Session(id: id, title: name, isBusy: object["status"] as? String == "busy",
                                     directory: cwd, updatedAt: updated)
    }

    /// Subagent transcripts of busy sessions written in the last minute.
    static func claudeSubagentsRunning(sessionIDs: [String], within window: TimeInterval = 60) -> Int {
        guard !sessionIDs.isEmpty else { return 0 }
        let projects = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for dir in dirs {
            for id in sessionIDs {
                let subagents = dir.appendingPathComponent(id).appendingPathComponent("subagents")
                guard let files = try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                count += files.filter {
                    $0.pathExtension == "jsonl"
                        && Date.now.timeIntervalSince(JSONLFollower.modificationDate($0)) < window
                }.count
            }
        }
        return count
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `rate_limit_event` lines in `claude -p --output-format stream-json` output.
    static func claudeUsage(fromStreamLine line: String, now: Date = .now) -> AgentOverview.Usage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "rate_limit_event",
              let info = object["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return nil }
        func window(_ key: String) -> (Double?, Date?) {
            let entry = windows[key] as? [String: Any]
            let percent = (entry?["utilization"] as? NSNumber).map { $0.doubleValue * 100 }
            let resets = (entry?["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (percent, resets)
        }
        let short = window("five_hour")
        let week = window("seven_day")
        return AgentOverview.Usage(shortWindowPercent: short.0, weeklyPercent: week.0,
                                   shortWindowResetsAt: short.1, weeklyResetsAt: week.1,
                                   plan: nil, observedAt: now)
    }

    // MARK: Codex

    /// Codex sessions whose log was written recently. A log written in the last minute is busy.
    static func codexSessions(within window: TimeInterval = 20 * 60, busyWithin: TimeInterval = 60) -> [AgentOverview.Session] {
        let titles = codexThreadNames()
        return CodexMonitor.recentLogFiles().compactMap { url in
            let modified = JSONLFollower.modificationDate(url)
            let age = Date.now.timeIntervalSince(modified)
            guard age < window else { return nil }
            let id = codexSessionID(fromLogName: url.lastPathComponent)
            return AgentOverview.Session(id: id, title: titles[id] ?? "Codex", isBusy: age < busyWithin,
                                         directory: nil, updatedAt: modified)
        }
    }

    /// "rollout-2026-09-18T11-59-01-01a0b273-fe64-7da3-8da3-da2f03408246.jsonl" → the UUID.
    static func codexSessionID(fromLogName name: String) -> String {
        let base = name.replacingOccurrences(of: ".jsonl", with: "")
        let parts = base.split(separator: "-")
        guard parts.count >= 5 else { return base }
        return parts.suffix(5).joined(separator: "-")
    }

    /// `~/.codex/session_index.jsonl`: thread id → name given in the Codex app.
    static func codexThreadNames() -> [String: String] {
        let url = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String, let name = object["thread_name"] as? String else { continue }
            names[id] = name
        }
        return names
    }

    /// The latest `rate_limits` Codex logged (every turn records them), from the newest logs.
    static func codexUsage() -> AgentOverview.Usage? {
        for url in CodexMonitor.recentLogFiles(days: 7).sorted(by: { JSONLFollower.modificationDate($0) > JSONLFollower.modificationDate($1) }).prefix(5) {
            guard let tail = tailText(of: url, bytes: 256 * 1024) else { continue }
            for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                if let usage = codexUsage(fromLogLine: String(line)) { return usage }
            }
        }
        return nil
    }

    static func codexUsage(fromLogLine line: String) -> AgentOverview.Usage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> (Double?, Date?) {
            let entry = limits[key] as? [String: Any]
            let percent = (entry?["used_percent"] as? NSNumber)?.doubleValue
            let resets = (entry?["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (percent, resets)
        }
        let primary = window("primary")
        let secondary = window("secondary")
        let observed = (object["timestamp"] as? String).flatMap(ClaudeTranscriptParser.parseDate) ?? .now
        return AgentOverview.Usage(shortWindowPercent: primary.0, weeklyPercent: secondary.0,
                                   shortWindowResetsAt: primary.1, weeklyResetsAt: secondary.1,
                                   plan: limits["plan_type"] as? String, observedAt: observed)
    }

    private static func tailText(of url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: handle.readData(ofLength: Int(min(size, bytes))), as: UTF8.self)
    }
}
