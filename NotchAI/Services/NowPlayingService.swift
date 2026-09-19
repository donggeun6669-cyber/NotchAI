import AppKit
import ApplicationServices
import Foundation
import Observation
import os

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
        /// Where it plays, as shown to the user ("Music", "YouTube Music", …).
        var label: String? = nil
        /// False when the player cannot tell playing from paused (a browser tab in the background).
        var stateKnown = true
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

        /// Music and Spotify are controlled through AppleScript; browser players through the
        /// system media keys (which needs the Accessibility permission).
        var controllable: Bool { self != .chrome }
    }

    private(set) var track: Track?
    /// Set when macOS refused the Apple Events permission, so the UI can explain it.
    private(set) var permissionDenied = false
    /// A new track just started; the collapsed notch shows it briefly.
    private(set) var changedAt: Date?

    private var isRefreshing = false
    private var lastRefresh = Date.distantPast
    private var missedReads = 0

    func poll(interval: TimeInterval = 3) {
        guard !isRefreshing, Date.now.timeIntervalSince(lastRefresh) >= interval else { return }
        lastRefresh = .now
        isRefreshing = true
        Task {
            let (found, denied) = await Self.currentTrack()
            isRefreshing = false
            permissionDenied = denied
            // One empty read (a song changing, Chrome busy) should not blank the track.
            if found == nil, track != nil, missedReads < 1 {
                missedReads += 1
                return
            }
            missedReads = 0
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

    /// Browser players can be controlled once the user has allowed Accessibility.
    var canUseMediaKeys: Bool { MediaKeys.isAllowed }

    private func run(_ command: Command) {
        guard let source = track?.source else { return }
        guard source.controllable else {
            // Chrome / the YouTube Music web app: same signal as the keyboard's ⏯ ⏭ ⏮ keys.
            if MediaKeys.isAllowed { MediaKeys.send(command) } else { MediaKeys.askForPermission() }
            return
        }
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
            // Chrome's AppleScript has no "is playing" for tabs, so list the tabs of music sites
            // (the YouTube Music app is a Chrome web app, so its window is listed here too).
            // Two Apple Events per window (all URLs, all titles) instead of two per tab: with many
            // tabs open, asking tab by tab took longer than the timeout and the track vanished.
            // Chrome ends a window's name with "🔊" while its active tab plays sound, which tells
            // playing from paused for the tab in front (third field: 1 / 0 / ? when not in front).
            let script = """
            tell application "Google Chrome"
                set out to ""
                repeat with w in windows
                    set us to URL of every tab of w
                    set ts to title of every tab of w
                    set frontIndex to active tab index of w
                    set speaking to (name of w) contains "🔊"
                    repeat with i from 1 to count of us
                        set u to item i of us
                        if u contains "music.youtube.com" or u contains "youtube.com/watch" or u contains "open.spotify.com" or u contains "soundcloud.com" then
                            set playState to "?"
                            if i = frontIndex then
                                if speaking then
                                    set playState to "1"
                                else
                                    set playState to "0"
                                end if
                            end if
                            set out to out & u & "|||" & (item i of ts) & "|||" & playState & linefeed
                        end if
                    end repeat
                end repeat
                return out
            end tell
            """
            let result = await AppleScript.run(script)
            guard let list = result.value else { return (nil, result == .notAuthorized) }
            return (Self.browserTrack(fromTabList: list), false)
        }
    }

    /// Picks the music tab from "url|||title" lines: YouTube Music first, then YouTube, Spotify, SoundCloud.
    nonisolated static func browserTrack(fromTabList list: String) -> Track? {
        let tabs = list.split(separator: "\n").compactMap { line -> (url: String, title: String, playing: Bool?)? in
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 2 else { return nil }
            let playing: Bool? = parts.count >= 3 ? (parts[2] == "1" ? true : parts[2] == "0" ? false : nil) : nil
            return (parts[0], parts[1].trimmingCharacters(in: .whitespaces), playing)
        }
        // A tab known to be playing wins over one that may be paused.
        let ordered = tabs.filter { $0.playing == true } + tabs.filter { $0.playing != true }
        for site in ["music.youtube.com", "youtube.com/watch", "open.spotify.com", "soundcloud.com"] {
            for tab in ordered where tab.url.contains(site) {
                guard var track = parseBrowserTitle(tab.title, site: site) else { continue }
                track.isPlaying = tab.playing ?? true
                track.stateKnown = tab.playing != nil
                return track
            }
        }
        return nil
    }

    /// Title of a music tab → track. Returns nil for a page that is not playing anything
    /// (e.g. the YouTube Music home page, titled just "YouTube Music").
    nonisolated static func parseBrowserTitle(_ raw: String, site: String) -> Track? {
        let title = cleanBrowserTitle(raw)
        guard !title.isEmpty, title != "YouTube Music", title != "YouTube", title != "Spotify" else { return nil }
        let label = site.contains("music.youtube") ? "YouTube Music"
            : site.contains("youtube") ? "YouTube"
            : site.contains("spotify") ? "Spotify Web" : "SoundCloud"
        // "Song • Artist" (Spotify web) → split.
        let parts = title.components(separatedBy: " • ")
        if parts.count >= 2 {
            return Track(title: parts[0], artist: parts[1...].joined(separator: " • "), source: .chrome, isPlaying: true, label: label)
        }
        return Track(title: title, artist: "", source: .chrome, isPlaying: true, label: label)
    }

    /// "Song name - YouTube" → "Song name".
    nonisolated static func cleanBrowserTitle(_ title: String) -> String {
        var text = title
        for suffix in [" - YouTube Music", " | YouTube Music", " - YouTube", " | YouTube",
                       " | Spotify", " - SoundCloud", " - Netflix"] {
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
                                                   arguments: ["-e", script], timeout: 8)
        guard let output else { return .failed }
        let result = classify(output)
        if case .failed = result {
            Logger(subsystem: "com.dongeun.NotchAI", category: "music")
                .info("osascript failed: \(output.prefix(300), privacy: .public)")
        }
        return result
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

/// The keyboard's media keys (⏯ ⏭ ⏮), sent as system events. macOS routes them to whatever is
/// playing — including YouTube Music in Chrome — so no browser setting has to change.
/// Posting them requires the Accessibility permission.
enum MediaKeys {
    // NX_KEYTYPE_PLAY / NEXT / PREVIOUS from IOKit's ev_keymap.h
    private static let play: Int32 = 16
    private static let next: Int32 = 17
    private static let previous: Int32 = 18

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings › Privacy & Security › Accessibility.
    static func askForPermission() {
        // The value of kAXTrustedCheckOptionPrompt (a global the Swift 6 compiler will not read).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func send(_ command: NowPlayingService.Command) {
        let key = switch command {
        case .playPause: play
        case .next: next
        case .previous: previous
        }
        post(key, down: true)
        post(key, down: false)
    }

    private static func post(_ key: Int32, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
