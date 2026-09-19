import Foundation
import Testing
@testable import NotchAI

struct NowPlayingTests {
    @Test func browserTitlesAreCleanedUp() {
        #expect(NowPlayingService.cleanBrowserTitle("NewJeans - Ditto - YouTube") == "NewJeans - Ditto")
        #expect(NowPlayingService.cleanBrowserTitle("(3) Lofi beats - YouTube") == "Lofi beats")
        #expect(NowPlayingService.cleanBrowserTitle("Some song | Spotify") == "Some song")
        #expect(NowPlayingService.cleanBrowserTitle("이렇게 좋아해 본 적이 없어요 (inst.) | YouTube Music")
                == "이렇게 좋아해 본 적이 없어요 (inst.)")
        #expect(NowPlayingService.cleanBrowserTitle("Plain title") == "Plain title")
    }

    @Test func musicTabsInChromeAreFound() {
        let list = """
        https://www.google.com/search?q=x|||x - Google Search
        https://music.youtube.com/watch?v=abc|||Hype Boy - YouTube Music
        https://www.youtube.com/watch?v=def|||(2) Lofi beats - YouTube
        """
        let track = NowPlayingService.browserTrack(fromTabList: list)
        #expect(track?.title == "Hype Boy")
        #expect(track?.label == "YouTube Music")
    }

    @Test func frontTabPlayStateComesFromTheSpeakerMark() {
        let paused = NowPlayingService.browserTrack(fromTabList: "https://music.youtube.com/watch?v=a|||Song | YouTube Music|||0")
        #expect(paused?.isPlaying == false && paused?.stateKnown == true)
        let background = NowPlayingService.browserTrack(fromTabList: "https://music.youtube.com/watch?v=a|||Song | YouTube Music|||?")
        #expect(background?.stateKnown == false)
        let list = "https://www.youtube.com/watch?v=x|||Paused video - YouTube|||0\nhttps://music.youtube.com/watch?v=a|||Playing song | YouTube Music|||1"
        #expect(NowPlayingService.browserTrack(fromTabList: list)?.title == "Playing song")
    }

    @Test func idleMusicHomePageIsNotATrack() {
        #expect(NowPlayingService.browserTrack(fromTabList: "https://music.youtube.com/|||YouTube Music") == nil)
        #expect(NowPlayingService.parseBrowserTitle("Ditto • NewJeans", site: "open.spotify.com")?.artist == "NewJeans")
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
    @Test func historySurvivesARestart() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clip-\(UUID().uuidString).json")
        ClipboardService(storeURL: url).record("keep me")
        #expect(ClipboardService(storeURL: url).entries.first?.text == "keep me")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func newestFirstNoDuplicatesAndCapped() {
        let clipboard = ClipboardService(storeURL: nil)
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
        let clipboard = ClipboardService(storeURL: nil)
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

struct OverviewTests {
    @Test func claudeSessionFileGivesTitleAndBusyState() {
        let json = #"{"pid":123,"sessionId":"abc","cwd":"/Users/x/DEAN","name":"검고담임 광고영상","status":"busy","kind":"interactive","updatedAt":1789828338232}"#
        let session = AgentOverviewReader.claudeSession(from: Data(json.utf8), isAlive: { _ in true })
        #expect(session?.title == "검고담임 광고영상")
        #expect(session?.isBusy == true)
    }

    @Test func exitedOrOneOffClaudeSessionsAreSkipped() {
        let json = #"{"pid":123,"sessionId":"abc","status":"idle","kind":"interactive"}"#
        #expect(AgentOverviewReader.claudeSession(from: Data(json.utf8), isAlive: { _ in false }) == nil)
        let print = #"{"pid":123,"sessionId":"abc","status":"busy","kind":"print"}"#
        #expect(AgentOverviewReader.claudeSession(from: Data(print.utf8), isAlive: { _ in true }) == nil)
    }

    @Test func unnamedClaudeSessionUsesItsFolder() {
        let json = #"{"pid":1,"sessionId":"a","cwd":"/Users/x/ReBridge","status":"idle"}"#
        #expect(AgentOverviewReader.claudeSession(from: Data(json.utf8), isAlive: { _ in true })?.title == "ReBridge")
    }

    @Test func claudeUsageFromRateLimitEvent() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.09,"resetsAt":1789827000},"seven_day":{"utilization":0.51,"resetsAt":1790082000}}}}"#
        let usage = AgentOverviewReader.claudeUsage(fromStreamLine: line)
        #expect(usage?.shortWindowPercent == 9)
        #expect(usage?.weeklyPercent == 51)
    }

    @Test func codexUsageFromTokenCount() {
        let line = #"{"timestamp":"2026-09-19T13:56:23.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":53.0,"window_minutes":300,"resets_at":1789845398},"secondary":{"used_percent":56.0,"window_minutes":10080,"resets_at":1789899259},"plan_type":"plus"}}}"#
        let usage = AgentOverviewReader.codexUsage(fromLogLine: line)
        #expect(usage?.shortWindowPercent == 53)
        #expect(usage?.weeklyPercent == 56)
        #expect(usage?.plan == "plus")
    }

    @Test func codexSessionIDComesFromTheLogName() {
        #expect(AgentOverviewReader.codexSessionID(fromLogName: "rollout-2026-09-18T11-59-01-01a0b273-fe64-7da3-8da3-da2f03408246.jsonl")
                == "01a0b273-fe64-7da3-8da3-da2f03408246")
    }

    @Test func currentTitlePrefersTheBusySession() {
        let overview = AgentOverview(sessions: [
            .init(id: "1", title: "idle but newer", isBusy: false, directory: nil, updatedAt: .now),
            .init(id: "2", title: "working", isBusy: true, directory: nil, updatedAt: .now.addingTimeInterval(-60)),
        ])
        #expect(overview.currentTitle == "working")
        #expect(overview.runningCount == 1)
    }
}

@MainActor
struct ChatTests {
    @Test func claudeStreamBuildsAConversation() {
        let chat = ChatSession()
        chat.add(.user, "안녕")
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/README.md"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"README를 읽었어요."}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"README를 읽었어요.","session_id":"s-1"}"#,
        ]
        lines.flatMap(ChatStreamParser.claude).forEach(chat.apply)
        #expect(chat.conversationID == "s-1")
        #expect(chat.messages.map(\.role) == [.user, .assistant])   // the step is gone once answered
        #expect(chat.messages.last?.text == "README를 읽었어요.")
    }

    @Test func codexStreamBuildsAConversation() {
        let chat = ChatSession()
        let lines = [
            #"{"type":"thread.started","thread_id":"t-9"}"#,
            #"{"type":"item.started","item":{"type":"command_execution","command":"ls"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"파일 3개가 있어요."}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ]
        lines.flatMap(ChatStreamParser.codex).forEach(chat.apply)
        #expect(chat.conversationID == "t-9")
        #expect(chat.messages.map(\.text) == ["파일 3개가 있어요."])
    }

    @Test func laterTurnsResumeTheConversation() {
        let first = GPTProvider.arguments(prompt: "hi", directory: URL(fileURLWithPath: "/tmp"), threadID: nil)
        #expect(first.contains("-C") && !first.contains("resume"))
        let next = GPTProvider.arguments(prompt: "and?", directory: URL(fileURLWithPath: "/tmp"), threadID: "t-9")
        #expect(next.starts(with: ["exec", "resume"]) && next.suffix(2) == ["t-9", "and?"])

        #expect(ClaudeProvider.arguments(prompt: "hi", model: .sonnet, conversationID: nil).contains("--resume") == false)
        #expect(ClaudeProvider.arguments(prompt: "and?", model: .sonnet, conversationID: "s-1").suffix(2) == ["--resume", "s-1"])
    }
}
