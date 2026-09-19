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

struct ScheduleTests {
    private static let sample = Data("""
    {"updated": "2026-09-19T01:12",
     "CL": [["09-21", "09:00", "11:45", "언어데이터과학", "31605호", ""],
            ["09-21", "13:30", "14:45", "영미여성문학", "31703호", ""]],
     "DL": [["09-19", "", "서포터즈 인터뷰"], ["09-20", "", "언데과 과제"], ["10-01", "", "산학 EXPO"]],
     "EV": [["09-21", "09-21", "18:00", "20:00", "HUSS 2회차"]]}
    """.utf8)

    private static let now = ScheduleService.date("09-19", time: "10:00", now: Date(timeIntervalSince1970: 1789779600))!

    @Test func parsesClassesDeadlinesAndEvents() {
        let snapshot = ScheduleService.parse(Self.sample, now: Self.now)
        #expect(snapshot.classes.count == 2)
        #expect(snapshot.classes.first?.name == "언어데이터과학")
        #expect(snapshot.classes.first?.room == "31605호")
        #expect(snapshot.deadlines.count == 3)
        #expect(snapshot.events.first?.title == "HUSS 2회차")
        #expect(snapshot.updated != nil)
    }

    @Test func missingOrBrokenFileGivesAnEmptySnapshot() {
        #expect(ScheduleService.parse(Data("not json".utf8)) == ScheduleService.Snapshot())
    }

    @Test func deadlinesCountDownFromToday() {
        let today = ScheduleService.date("09-19", time: "12:00", now: Self.now)!
        let tomorrow = ScheduleService.date("09-20", time: "12:00", now: Self.now)!
        #expect(ScheduleService.daysLeft(today, from: Self.now) == 0)
        #expect(ScheduleService.daysLeft(tomorrow, from: Self.now) == 1)
    }

    @Test func aDateFarInThePastBelongsToNextYear() {
        // Late December, looking at a January date.
        let december = ScheduleService.date("12-28", time: "09:00", now: Self.now)!
        let january = ScheduleService.date("01-05", time: "09:00", now: december)!
        #expect(january > december)
    }
}

@MainActor
struct DraftTests {
    @Test func deskPutsTextIntoTheCommandField() {
        let app = AppModel(providers: [ClaudeProvider()])
        app.insertIntoDraft("첫 줄")
        #expect(app.draft == "첫 줄")
        #expect(app.focusRequestedAt != nil)

        app.insertIntoDraft("\"/tmp/report.pdf\"")
        #expect(app.draft == "첫 줄 \"/tmp/report.pdf\"")
    }
}
