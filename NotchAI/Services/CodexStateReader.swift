import Foundation
import SQLite3

/// Reads the state the Codex app keeps in SQLite: which threads are open, what they are called,
/// and which one is running. Read-only, and the databases are opened read-only.
///
/// The rollout logs alone are not enough: a thread opened days ago writes into its old day
/// folder, Codex's own guardian subagents write logs that look like sessions, and the thread
/// name file (`session_index.jsonl`) stopped being updated by the app.
enum CodexStateReader {
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser
    nonisolated static let codexURL = home.appendingPathComponent(".codex")
    /// One empty file per thread the app currently holds open.
    nonisolated static let locksURL = codexURL.appendingPathComponent("thread-writer-locks")
    /// A thread quiet for longer than this is not part of "what is open right now".
    nonisolated static let openWindow: TimeInterval = 20 * 60
    /// An `inProgress` turn left behind by a crash should not show as working forever.
    nonisolated static let runningWindow: TimeInterval = 10 * 60

    struct Snapshot: Equatable {
        var sessions: [AgentOverview.Session] = []
        /// Codex's own helper threads (guardian reviews and other subagents) running now.
        var subagentsRunning = 0
        /// Logs of the user's own threads, for the state follower.
        var logPaths: [String] = []
    }

    struct Thread {
        var id: String
        var name: String
        var title: String
        var cwd: String
        var source: String
        var threadSource: String
        var updatedAt: Date
        var rolloutPath: String
    }

    /// nil when the databases cannot be read (Codex not installed, or a schema change):
    /// the caller then falls back to reading the logs.
    nonisolated static func read(now: Date = .now) -> Snapshot? {
        guard let state = database(named: "state"), let threads = threads(in: state, now: now) else { return nil }
        let locked = openThreadIDs()
        let running = runningThreadIDs()

        var snapshot = Snapshot()
        for thread in threads {
            let isOpen = locked.contains(thread.id) || now.timeIntervalSince(thread.updatedAt) < openWindow
            guard isOpen else { continue }
            guard isUserThread(source: thread.source, threadSource: thread.threadSource) else {
                // Guardian reviews and other helper threads count like Claude's subagents.
                if locked.contains(thread.id) { snapshot.subagentsRunning += 1 }
                continue
            }
            let busy = running.contains(thread.id) && now.timeIntervalSince(thread.updatedAt) < runningWindow
            snapshot.sessions.append(AgentOverview.Session(id: thread.id, title: title(of: thread), isBusy: busy,
                                                           directory: thread.cwd.isEmpty ? nil : thread.cwd,
                                                           updatedAt: thread.updatedAt))
            if !thread.rolloutPath.isEmpty { snapshot.logPaths.append(thread.rolloutPath) }
        }
        return snapshot
    }

    /// `codex exec` runs and Codex's internal subagents are not sessions the user opened.
    nonisolated static func isUserThread(source: String, threadSource: String) -> Bool {
        let source = source.lowercased()
        let threadSource = threadSource.lowercased()
        if source.contains("subagent") || threadSource.contains("guardian") || threadSource.contains("subagent") {
            return false
        }
        return source != "exec"
    }

    /// The name given in the app; failing that the summary Codex wrote. Some threads carry a
    /// whole prompt in `title`, so only a short first line is usable.
    nonisolated static func title(of thread: Thread) -> String {
        let name = thread.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let firstLine = thread.title.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty && firstLine.count <= 80 { return firstLine }
        let folder = URL(fileURLWithPath: thread.cwd).lastPathComponent
        return folder.isEmpty ? "Codex" : folder
    }

    /// Thread ids the app holds a writer lock on (`<id>.lock`).
    nonisolated static func openThreadIDs() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: locksURL, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "lock" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.hasPrefix(".") })
    }

    private nonisolated static func runningThreadIDs() -> Set<String> {
        guard let history = database(named: "thread_history") else { return [] }
        let rows = query(history, "SELECT thread_id FROM thread_turns WHERE status = 'inProgress'", columns: 1) ?? []
        return Set(rows.compactMap { $0.first ?? nil })
    }

    private nonisolated static func threads(in path: String, now: Date) -> [Thread]? {
        let since = Int((now.timeIntervalSince1970 - 24 * 3600) * 1000)
        let full = """
        SELECT id, COALESCE(name, ''), title, cwd, source, COALESCE(thread_source, ''), updated_at_ms, rollout_path
        FROM threads WHERE archived = 0 AND updated_at_ms > \(since) ORDER BY updated_at_ms DESC LIMIT 40
        """
        // Older builds of the app have neither `name` nor `thread_source`.
        let basic = """
        SELECT id, '', title, cwd, source, '', updated_at_ms, rollout_path
        FROM threads WHERE updated_at_ms > \(since) ORDER BY updated_at_ms DESC LIMIT 40
        """
        let rows = query(path, full, columns: 8) ?? query(path, basic, columns: 8)
        guard let rows else { return nil }
        return rows.map { row in
            Thread(id: row[0] ?? "", name: row[1] ?? "", title: row[2] ?? "", cwd: row[3] ?? "",
                   source: row[4] ?? "", threadSource: row[5] ?? "",
                   updatedAt: Date(timeIntervalSince1970: (Double(row[6] ?? "0") ?? 0) / 1000),
                   rolloutPath: row[7] ?? "")
        }
    }

    /// `state_5.sqlite`, `thread_history_1.sqlite`: the app bumps the number when the schema
    /// changes, so take the highest one present.
    nonisolated static func database(named prefix: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: codexURL, includingPropertiesForKeys: nil)) ?? []
        let matches = files.map(\.lastPathComponent).filter {
            $0.hasPrefix(prefix + "_") && $0.hasSuffix(".sqlite")
        }
        guard let newest = matches.max(by: { version(of: $0, prefix: prefix) < version(of: $1, prefix: prefix) })
        else { return nil }
        return codexURL.appendingPathComponent(newest).path
    }

    nonisolated static func version(of file: String, prefix: String) -> Int {
        Int(file.dropFirst(prefix.count + 1).replacingOccurrences(of: ".sqlite", with: "")) ?? 0
    }

    /// Read-only query. Returns nil if the database or the statement cannot be used, so the
    /// caller can fall back instead of showing nothing.
    private nonisolated static func query(_ path: String, _ sql: String, columns: Int) -> [[String?]]? {
        var handle: OpaquePointer?
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }
        // The app writes constantly; give up rather than hold anything up.
        sqlite3_busy_timeout(handle, 200)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        var rows: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return rows.isEmpty ? nil : rows }
            rows.append((0..<columns).map { index in
                sqlite3_column_text(statement, Int32(index)).map { String(cString: $0) }
            })
        }
        return rows
    }
}
