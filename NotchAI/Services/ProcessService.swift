import Foundation

/// Finds command-line tools and runs them, streaming stdout line by line.
enum ProcessService {
    struct ShellEnvironment: Sendable {
        let path: String
        func executable(named name: String) -> URL? {
            for dir in path.split(separator: ":") {
                let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
            return nil
        }
    }

    /// Apps launched from Finder get a minimal PATH, so ask the user's login shell for theirs
    /// (needed to find `claude`, `codex`, and `node` for npm-installed tools).
    static func loadShellEnvironment() async -> ShellEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "/opt/homebrew/bin",
                        "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        let marker = "__NOTCHAI_PATH__"
        let output = try? await run(URL(fileURLWithPath: "/bin/zsh"),
                                    arguments: ["-lic", "printf '\(marker)%s' \"$PATH\""],
                                    timeout: 5)
        guard let output, let range = output.range(of: marker, options: .backwards) else {
            return ShellEnvironment(path: fallback)
        }
        let shellPath = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellEnvironment(path: shellPath.isEmpty ? fallback : shellPath + ":" + fallback)
    }

    /// Loaded once per launch.
    static let shell: Task<ShellEnvironment, Never> = Task { await loadShellEnvironment() }

    /// Runs a short command and returns stdout and stderr together.
    static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Environment for agent processes: the user's PATH, and never an API key, so the CLIs use
    /// their own subscription login instead of billing an API account.
    static func agentEnvironment(shell: ShellEnvironment) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shell.path
        // Also drop settings inherited from a parent Claude session (e.g. the desktop app's proxy
        // URL), so the CLI can only use its own login.
        for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_")
            || key == "CLAUDECODE" || key == "OPENAI_API_KEY" || key == "CODEX_API_KEY" {
            env.removeValue(forKey: key)
        }
        return env
    }
}

/// A long-running agent command (`claude -p …`, `codex exec …`) whose stdout is JSON lines.
@MainActor
final class StreamingProcess {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lineBuffer = LineBuffer()
    private let errorBuffer = LineBuffer()

    var onLine: ((String) -> Void)?
    /// Exit code and the last stderr lines.
    var onExit: ((Int32, String) -> Void)?

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        let lines = lineBuffer
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let complete = lines.append(handle.availableData)
            guard !complete.isEmpty else { return }
            Task { @MainActor in complete.forEach { self?.onLine?($0) } }
        }
        let errors = errorBuffer
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = errors.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.stdout.fileHandleForReading.readabilityHandler = nil
                self.stderr.fileHandleForReading.readabilityHandler = nil
                // Lines that arrived just before exit.
                let rest = lines.append(self.stdout.fileHandleForReading.readDataToEndOfFile()) + lines.flush()
                rest.forEach { self.onLine?($0) }
                self.onExit?(status, errors.flushAll())
            }
        }
        try process.run()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// Splits incoming bytes into lines. Used from pipe callbacks on background threads.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var all: [String] = []

    /// Adds bytes and returns the lines completed by them.
    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        all.append(contentsOf: lines)
        if all.count > 20 { all.removeFirst(all.count - 20) }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        pending.removeAll()
        return line.isEmpty ? [] : [line]
    }

    /// Everything seen recently, for error messages.
    func flushAll() -> String {
        let tail = flush()
        lock.lock(); defer { lock.unlock() }
        return (all + tail).suffix(5).joined(separator: "\n")
    }
}

/// Follows the newest `.jsonl` file among a set of candidates and hands over new lines.
/// Polling keeps it simple and needs no permissions; the files are only read, never written.
@MainActor
final class JSONLFollower {
    private let candidates: () -> [URL]
    private var currentURL: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// Called with the new file's recent lines when a different file becomes the newest one.
    var onSwitch: ((URL, [String]) -> Void)?
    var onLines: (([String]) -> Void)?

    init(candidates: @escaping () -> [URL]) {
        self.candidates = candidates
    }

    /// Finding the newest file means listing every candidate, so only do that every few polls;
    /// in between just read what was appended to the current file.
    private static let rescanEvery = 4
    private var pollsSinceScan = JSONLFollower.rescanEvery

    func poll() {
        pollsSinceScan += 1
        if pollsSinceScan >= Self.rescanEvery || currentURL == nil {
            pollsSinceScan = 0
            guard let newest = Self.newest(candidates()) else { return }
            if newest != currentURL {
                switchTo(newest)
                return
            }
        }
        readAppended()
    }

    private func switchTo(_ newest: URL) {
        currentURL = newest
        let (tail, size) = Self.readTail(of: newest, bytes: 128 * 1024)
        offset = size
        partial.removeAll()
        onSwitch?(newest, tail)
    }

    private func readAppended() {
        guard let newest = currentURL else { return }
        guard let handle = try? FileHandle(forReadingFrom: newest) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? offset
        if size < offset { offset = 0 }   // file was replaced
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: Int(size - offset))
        offset = size
        partial.append(data)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            lines.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
            partial.removeSubrange(partial.startIndex...newline)
        }
        if !lines.isEmpty { onLines?(lines) }
    }

    private static func newest(_ urls: [URL]) -> URL? {
        urls.max { modificationDate($0) < modificationDate($1) }
    }

    nonisolated static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func readTail(of url: URL, bytes: UInt64) -> ([String], UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        let data = handle.readData(ofLength: Int(size - start))
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // first line may be cut
        // An unfinished last line would be read again on the next poll, so stop before it.
        if data.last != 0x0A, !lines.isEmpty {
            let cut = lines.removeLast()
            return (lines, size - UInt64(cut.utf8.count))
        }
        return (lines, size)
    }
}
