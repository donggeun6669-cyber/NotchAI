import Foundation
import Observation

/// Repositories with work that is not committed or not pushed yet.
/// Read-only: it runs `git status` / `git log` in one background shell and never writes.
@MainActor
@Observable
final class GitStatusService {
    struct Repo: Identifiable, Equatable {
        let path: String
        let branch: String
        /// Tracked files with changes.
        let changed: Int
        /// New files git does not know about yet — usually the newest work of all.
        let untracked: Int
        /// Commits the remote does not have yet.
        let ahead: Int
        let hasUpstream: Bool
        let lastCommit: Date?

        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        /// Something the user still has to do: save it, or push it.
        var needsAttention: Bool { changed > 0 || untracked > 0 || ahead > 0 || !hasUpstream }
    }

    nonisolated static let refreshInterval: TimeInterval = 90
    /// Where repositories live. DEAN's `code` links point here too.
    nonisolated static let searchRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/GitHub")

    private(set) var repos: [Repo] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    @ObservationIgnored private var running: Task<Void, Never>?

    var pending: [Repo] { repos.filter(\.needsAttention) }

    func poll() {
        guard Date.now.timeIntervalSince(lastRefresh ?? .distantPast) >= Self.refreshInterval else { return }
        refresh()
    }

    func refresh() {
        guard running == nil else { return }
        isRefreshing = true
        running = Task { [weak self] in
            let paths = await Task.detached(priority: .utility) { Self.repositoryPaths() }.value
            let output = await Task.detached(priority: .utility) { Self.readStatus(of: paths) }.value
            guard let self else { return }
            repos = Self.parse(output).sorted(by: Self.order)
            lastRefresh = .now
            isRefreshing = false
            running = nil
        }
    }

    /// Needs attention first, then by how recently it was touched.
    nonisolated static func order(_ a: Repo, _ b: Repo) -> Bool {
        if a.needsAttention != b.needsAttention { return a.needsAttention }
        return (a.lastCommit ?? .distantPast) > (b.lastCommit ?? .distantPast)
    }

    /// Every git checkout directly under the search root, plus the ones DEAN's project links
    /// point at (a link may lead somewhere else entirely).
    nonisolated static func repositoryPaths() -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        let children = (try? fm.contentsOfDirectory(at: searchRoot, includingPropertiesForKeys: nil)) ?? []
        paths += children.map(\.path)
        paths += LauncherService.projectCodeLinks().map(\.path)
        var seen = Set<String>()
        return paths
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { fm.fileExists(atPath: $0 + "/.git") && seen.insert($0).inserted }
    }

    /// One shell for all repositories: a line per repo, tab separated.
    nonisolated static func readStatus(of paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        let list = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = """
        for d in \(list); do
          b=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
          c=$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
          n=$(git -C "$d" status --porcelain 2>/dev/null | grep -c '^??')
          if git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
            a=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null); u=1
          else
            a=0; u=0
          fi
          t=$(git -C "$d" log -1 --format=%ct 2>/dev/null)
          printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$d" "$b" "$c" "$a" "$u" "$t"
        done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// "path, branch, changed, ahead, hasUpstream, lastCommitEpoch, untracked" per line, tab separated.
    nonisolated static func parse(_ output: String) -> [Repo] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 7 else { return nil }
            return Repo(path: fields[0],
                        branch: fields[1],
                        changed: Int(fields[2]) ?? 0,
                        untracked: Int(fields[6]) ?? 0,
                        ahead: Int(fields[3]) ?? 0,
                        hasUpstream: fields[4] == "1",
                        lastCommit: Double(fields[5]).map { Date(timeIntervalSince1970: $0) })
        }
    }
}
