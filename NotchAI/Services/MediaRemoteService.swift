import AppKit
import Foundation

/// The system's "Now Playing" (what Control Center shows) through mediaremote-adapter
/// (Vendor/mediaremote-adapter, BSD-3). macOS 15.4+ only lets entitled system binaries read
/// MediaRemote, so the adapter runs its helper framework inside `/usr/bin/perl`.
///
/// This covers every player at once — YouTube Music in Chrome or as a web app, Spotify, Music —
/// with title, artist, play state and artwork, and pushes changes instead of being polled.
/// If the adapter is missing or macOS breaks it, `isAvailable` stays false and the notch falls
/// back to asking players with AppleScript.
@MainActor
final class MediaRemoteService {
    /// The now playing state; nil when nothing is playing.
    var onUpdate: ((NowPlayingService.Track?) -> Void)?
    private(set) var isAvailable = false

    private var process: StreamingProcess?
    private var state: [String: Any] = [:]
    private var restarts = 0

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    /// `Contents/Resources/MediaRemoteAdapter/` (copied there by the build).
    private static var folder: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("MediaRemoteAdapter") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static func arguments(_ command: [String], includeTestClient: Bool = false) -> [String]? {
        guard let folder else { return nil }
        var arguments = [folder.appendingPathComponent("mediaremote-adapter.pl").path,
                         folder.appendingPathComponent("MediaRemoteAdapter.framework").path]
        if includeTestClient { arguments.append(folder.appendingPathComponent("MediaRemoteAdapterTestClient").path) }
        return arguments + command
    }

    /// Runs the adapter's self-test, then starts streaming. Calls back with `false` if unusable.
    func start(onUnavailable: @escaping () -> Void) {
        Self.killOrphanedStreams()
        guard let test = Self.arguments(["test"], includeTestClient: true) else {
            onUnavailable()
            return
        }
        Task {
            let ok = await Self.exitsCleanly(test)
            guard ok else {
                onUnavailable()
                return
            }
            isAvailable = true
            startStream()
        }
    }

    private func startStream() {
        guard let arguments = Self.arguments(["stream", "--debounce=150"]) else { return }
        let process = StreamingProcess(executable: Self.perl, arguments: arguments,
                                       directory: FileManager.default.temporaryDirectory,
                                       environment: ProcessInfo.processInfo.environment)
        process.onLine = { [weak self] line in self?.handle(line) }
        process.onExit = { [weak self] _, _ in
            guard let self else { return }
            self.process = nil
            // Restart a few times (e.g. after sleep); after that give up on this launch.
            self.restarts += 1
            if self.restarts <= 3 {
                Task { try? await Task.sleep(for: .seconds(2)); self.startStream() }
            }
        }
        do {
            try process.start()
            self.process = process
        } catch {
            isAvailable = false
        }
    }

    func stop() {
        restarts = .max   // do not restart after this
        process?.terminate()
    }

    /// If NotchAI was killed (not quit), its `perl … stream` child keeps running with launchd as
    /// its parent. Clean those up so relaunches do not pile up helpers.
    private static func killOrphanedStreams() {
        guard let folder else { return }
        let marker = folder.appendingPathComponent("mediaremote-adapter.pl").path
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        for pid in orphanedStreamPIDs(psOutput: output, marker: marker) {
            kill(pid, SIGTERM)
        }
    }

    /// PIDs of adapter stream processes whose parent is launchd (pid 1).
    nonisolated static func orphanedStreamPIDs(psOutput: String, marker: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), fields[1] == "1",
                  fields[2].contains(marker), fields[2].contains(" stream") else { return nil }
            return pid
        }
    }

    private func handle(_ line: String) {
        guard let update = Self.parseStreamLine(line) else { return }
        state = Self.merge(state, update.payload, isDiff: update.isDiff)
        onUpdate?(Self.track(from: state))
    }

    // MARK: Commands

    /// MRCommand ids: 2 = toggle play/pause, 4 = next track, 5 = previous track.
    func send(_ command: NowPlayingService.Command) {
        let id = switch command {
        case .playPause: "2"
        case .next: "4"
        case .previous: "5"
        }
        guard let arguments = Self.arguments(["send", id]) else { return }
        Task { _ = await Self.exitsCleanly(arguments) }
    }

    private static func exitsCleanly(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = perl
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    // MARK: Parsing (pure, tested)

    /// `{"type":"data","diff":true,"payload":{...}}`
    nonisolated static func parseStreamLine(_ line: String) -> (isDiff: Bool, payload: [String: Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return (object["diff"] as? Bool ?? false, payload)
    }

    /// A diff updates the last full state; keys set to null are removed.
    nonisolated static func merge(_ state: [String: Any], _ payload: [String: Any], isDiff: Bool) -> [String: Any] {
        var merged = isDiff ? state : [:]
        for (key, value) in payload {
            if value is NSNull { merged.removeValue(forKey: key) } else { merged[key] = value }
        }
        return merged
    }

    nonisolated static func track(from state: [String: Any]) -> NowPlayingService.Track? {
        guard let title = state["title"] as? String, !title.isEmpty else { return nil }
        let bundleID = state["parentApplicationBundleIdentifier"] as? String ?? state["bundleIdentifier"] as? String
        let artwork = (state["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
        return NowPlayingService.Track(title: title,
                                       artist: state["artist"] as? String ?? "",
                                       source: .system,
                                       isPlaying: state["playing"] as? Bool ?? false,
                                       label: bundleID.map(appName),
                                       stateKnown: true,
                                       artwork: artwork)
    }

    /// "com.google.Chrome" → "Google Chrome".
    nonisolated static func appName(_ bundleID: String) -> String {
        let known = ["com.google.Chrome": "Chrome", "com.spotify.client": "Spotify", "com.apple.Music": "Music",
                     "com.apple.Safari": "Safari", "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod": "YouTube Music"]
        if let name = known[bundleID] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
