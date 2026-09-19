import Foundation
import Testing
@testable import NotchAI

struct NowPlayingTests {
    @Test func browserTitlesAreCleanedUp() {
        #expect(NowPlayingService.cleanBrowserTitle("NewJeans - Ditto - YouTube") == "NewJeans - Ditto")
        #expect(NowPlayingService.cleanBrowserTitle("(3) Lofi beats - YouTube") == "Lofi beats")
        #expect(NowPlayingService.cleanBrowserTitle("Some song | Spotify") == "Some song")
        #expect(NowPlayingService.cleanBrowserTitle("Plain title") == "Plain title")
    }

    @Test func onlyMusicAndSpotifyCanBeControlled() {
        #expect(NowPlayingService.Source.music.controllable)
        #expect(NowPlayingService.Source.spotify.controllable)
        #expect(!NowPlayingService.Source.chrome.controllable)
    }

    @Test func automationRefusalIsRecognised() {
        #expect(AppleScript.classify("execution error: Not authorized to send Apple events to Google Chrome. (-1743)") == .notAuthorized)
        #expect(AppleScript.classify("execution error: Music got an error (-1728)") == .failed)
        #expect(AppleScript.classify("Song\nArtist\nplaying") == .ok("Song\nArtist\nplaying"))
    }

    @Test func commandsTargetTheRightApp() {
        #expect(NowPlayingService.Command.playPause.script(for: .spotify) == "tell application \"Spotify\" to playpause")
        #expect(NowPlayingService.Command.next.script(for: .music) == "tell application \"Music\" to next track")
    }
}

@MainActor
struct ClipboardTests {
    @Test func newestFirstNoDuplicatesAndCapped() {
        let clipboard = ClipboardService()
        for index in 0..<(ClipboardService.limit + 4) {
            clipboard.record("item \(index)")
        }
        #expect(clipboard.entries.count == ClipboardService.limit)
        #expect(clipboard.entries.first?.text == "item \(ClipboardService.limit + 3)")

        clipboard.record("item 5")
        #expect(clipboard.entries.first?.text == "item 5")
        #expect(clipboard.entries.filter { $0.text == "item 5" }.count == 1)
    }

    @Test func blankTextIsIgnored() {
        let clipboard = ClipboardService()
        clipboard.record("   \n ")
        #expect(clipboard.entries.isEmpty)
    }
}

@MainActor
struct ShelfTests {
    @Test func addsWithoutDuplicatesAndPrunesMissingFiles() throws {
        let shelf = ShelfService(persists: false)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        shelf.add([file])
        shelf.add([file])
        #expect(shelf.items.count == 1)

        try FileManager.default.removeItem(at: file)
        shelf.prune()
        #expect(shelf.items.isEmpty)
    }
}

@MainActor
struct ChromeTests {
    @Test func promptGetsThePageOnlyWhenAsked() {
        let chrome = ChromeService()
        chrome.attachesTab = false
        chrome.frontTab = ChromeService.Tab(title: "Vercel Dashboard", url: "https://vercel.com")
        #expect(chrome.decorate("Fix the deploy") == "Fix the deploy")

        chrome.attachesTab = true
        chrome.frontTab = ChromeService.Tab(title: "Vercel Dashboard", url: "https://vercel.com")
        let decorated = chrome.decorate("Fix the deploy")
        #expect(decorated.contains("https://vercel.com"))
        #expect(decorated.hasSuffix("Fix the deploy"))
    }
}
