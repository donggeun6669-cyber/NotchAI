import AppKit
import Foundation
import Observation

/// What is playing right now.
///
/// macOS no longer lets other apps read the system "Now Playing" info, which is why notch apps
/// often show the wrong track. Instead this asks the players themselves (Music, Spotify) with
/// AppleScript, and falls back to the title of a Chrome tab that is playing audio (YouTube etc.).
/// Only apps that are already running are asked, so nothing is ever launched.
@MainActor
@Observable
final class NowPlayingService {
    struct Track: Equatable {
        var title: String
        var artist: String
        var source: Source
        var isPlaying: Bool
    }

    enum Source: String, Equatable, Sendable {
        case music = "Music"
        case spotify = "Spotify"
        case chrome = "Chrome"

        var bundleID: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            case .chrome: "com.google.Chrome"
            }
        }

        /// Only Music and Spotify can be controlled through AppleScript.
        var controllable: Bool { self != .chrome }
    }

    private(set) var track: Track?
    /// Set when macOS refused the Apple Events permission, so the UI can explain it.
    private(set) var permissionDenied = false
    /// A new track just started; the collapsed notch shows it briefly.
    private(set) var changedAt: Date?

    private var isRefreshing = false
    private var lastRefresh = Date.distantPast

    func poll(interval: TimeInterval = 3) {
        guard !isRefreshing, Date.now.timeIntervalSince(lastRefresh) >= interval else { return }
        lastRefresh = .now
        isRefreshing = true
        Task {
            let (found, denied) = await Self.currentTrack()
            isRefreshing = false
            permissionDenied = denied
            guard found != track else { return }
            if found?.title != track?.title, found != nil { changedAt = .now }
            track = found
        }
    }

    func playPause() { run(.playPause) }
    func next() { run(.next) }
    func previous() { run(.previous) }

    enum Command: Sendable {
        case playPause, next, previous

        func script(for source: Source) -> String {
            let app = source.rawValue
            switch self {
            case .playPause: return "tell application \"\(app)\" to playpause"
            case .next: return "tell application \"\(app)\" to next track"
            case .previous: return "tell application \"\(app)\" to previous track"
            }
        }
    }

    private func run(_ command: Command) {
        guard let source = track?.source, source.controllable else { return }
        Task {
            _ = await AppleScript.run(command.script(for: source))
            lastRefresh = .distantPast
            poll(interval: 0)
        }
    }

    /// Asks each running player in turn; the first one that is playing wins.
    /// Also reports whether macOS blocked the request, so the UI can point at the setting.
    static func currentTrack() async -> (track: Track?, permissionDenied: Bool) {
        var paused: Track?
        var denied = false
        for source in [Source.music, .spotify, .chrome] {
            guard await AppleScript.isRunning(bundleID: source.bundleID) else { continue }
            let (track, notAuthorized) = await read(source)
            if notAuthorized { denied = true }
            guard let track else { continue }
            if track.isPlaying { return (track, denied) }
            if paused == nil { paused = track }
        }
        return (paused, denied)
    }

    private static func read(_ source: Source) async -> (Track?, Bool) {
        switch source {
        case .music, .spotify:
            let app = source.rawValue
            let script = """
            tell application "\(app)"
                if player state is stopped then return ""
                set t to name of current track
                set a to artist of current track
                return t & "\\n" & a & "\\n" & (player state as text)
            end tell
            """
            let result = await AppleScript.run(script)
            guard let output = result.value else { return (nil, result == .notAuthorized) }
            let parts = output.components(separatedBy: "\n")
            guard parts.count >= 3, !parts[0].isEmpty else { return (nil, false) }
            return (Track(title: parts[0], artist: parts[1], source: source,
                          isPlaying: parts[2].contains("playing")), false)
        case .chrome:
            // Chrome marks tabs that are making sound with "audible".
            let script = """
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        if audible of t then return title of t
                    end repeat
                end repeat
            end tell
            return ""
            """
            let result = await AppleScript.run(script)
            guard let title = result.value, !title.isEmpty else { return (nil, result == .notAuthorized) }
            return (Track(title: Self.cleanBrowserTitle(title), artist: "Chrome", source: .chrome,
                          isPlaying: true), false)
        }
    }

    /// "Song name - YouTube" → "Song name".
    nonisolated static func cleanBrowserTitle(_ title: String) -> String {
        var text = title
        for suffix in [" - YouTube", " - YouTube Music", " | Spotify", " - SoundCloud", " - Netflix"] {
            if text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        }
        if text.hasPrefix("(") , let close = text.firstIndex(of: ")") {   // "(3) Title" unread badge
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// Runs AppleScript through `osascript` in a child process, so a slow or blocked script never
/// freezes the notch. The first call to each app makes macOS ask for Automation permission.
enum AppleScript {
    @MainActor
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    enum Result: Equatable {
        case ok(String)
        /// The user has not allowed (or has denied) controlling that app in
        /// System Settings › Privacy & Security › Automation.
        case notAuthorized
        case failed

        var value: String? { if case .ok(let text) = self { text } else { nil } }
    }

    static func run(_ script: String) async -> Result {
        let output = try? await ProcessService.run(URL(fileURLWithPath: "/usr/bin/osascript"),
                                                   arguments: ["-e", script], timeout: 5)
        guard let output else { return .failed }
        return classify(output)
    }

    /// osascript writes errors to the same stream as the result.
    static func classify(_ output: String) -> Result {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-1743") || trimmed.localizedCaseInsensitiveContains("not allowed")
            || trimmed.localizedCaseInsensitiveContains("not authorized") {
            return .notAuthorized
        }
        if trimmed.contains("execution error") || trimmed.contains("syntax error") { return .failed }
        return .ok(trimmed)
    }

    /// Opens the Automation list in System Settings.
    @MainActor
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
