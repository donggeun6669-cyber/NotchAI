import Foundation
import Testing
@testable import NotchAI

struct LauncherTests {
    @Test func nestedProjectsKeepTheirGroupInTheName() {
        let dean = LauncherService.deanURL.appendingPathComponent("03_PROJECTS")
        #expect(LauncherService.projectName(ofCodeLink: dean.appendingPathComponent("NotchAI/code")) == "NotchAI")
        #expect(LauncherService.projectName(ofCodeLink: dean.appendingPathComponent("JeparkENG/QM/code"))
                == "JeparkENG · QM")
        // In the launcher list the group alone is the name.
        #expect(LauncherService.shortProjectName(ofCodeLink: dean.appendingPathComponent("JeparkENG/QM/code"))
                == "JeparkENG")
    }

    @Test func aProjectsOwnAddressIsTakenFromTheLineThatRecordsIt() {
        #expect(LauncherService.deploymentURL(inLine: "라이브: https://gumgomentor.vercel.app")
                == "https://gumgomentor.vercel.app")
        #expect(LauncherService.deploymentURL(inLine: "배포: https://jepark-admin.vercel.app — 2026-09-19 다시 연결")
                == "https://jepark-admin.vercel.app")
        // No word saying this is where the project lives.
        #expect(LauncherService.deploymentURL(inLine: "참고 자료 https://admission.skku.edu/notice") == nil)
        // The code host is not the project's own page.
        #expect(LauncherService.deploymentURL(inLine: "배포 저장소 https://github.com/owner/repo") == nil)
    }

    @Test func targetsKnowHowToBeOpened() {
        let terminal = LauncherService.Target(label: "터미널", symbol: nil, value: "term:~/dev/GitHub/NotchAI")
        #expect(terminal.isTerminal)
        #expect(terminal.url?.path.hasSuffix("dev/GitHub/NotchAI") == true)

        let page = LauncherService.Target(label: "GitHub", symbol: nil, value: "https://github.com/owner/repo")
        #expect(!page.isTerminal)
        #expect(page.url?.scheme == "https")
    }
}

@MainActor
struct LauncherEditingTests {
    private func launcher() -> LauncherService { LauncherService(load: false, storeURL: nil) }

    @Test func foldersAndFilesAreAddedOnceAndNamedAfterThemselves() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LauncherTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("보고서.pdf")
        try Data().write(to: file)

        let list = launcher()
        list.add([folder, file, file])
        #expect(list.items.map(\.name) == [folder.lastPathComponent, "보고서"])
        #expect(list.items[0].targets[0].icon == "folder")
        #expect(list.items[1].targets[0].icon == "doc")
    }

    @Test func aWebsiteGetsAnAddressAndANameEvenWhenLeftBlank() {
        let list = launcher()
        #expect(list.addWebsite(name: "", address: "naver.com"))
        #expect(list.addWebsite(name: "메일", address: "https://mail.google.com"))
        #expect(!list.addWebsite(name: "x", address: "not an address"))
        #expect(list.items.map(\.name) == ["naver.com", "메일"])
        #expect(list.items[0].targets[0].value == "https://naver.com")
    }

    @Test func removingTheLastButtonRemovesTheItem() {
        let list = launcher()
        list.addWebsite(name: "A", address: "a.com")
        list.addWebsite(name: "B", address: "b.com")
        list.remove(list.items[0].targets[0])
        #expect(list.items.map(\.name) == ["B"])
    }

    @Test func webAddressesAreRecognised() {
        #expect(LauncherService.webAddress("  skku.edu ") == "https://skku.edu")
        #expect(LauncherService.webAddress("http://localhost:3000") == "http://localhost:3000")
        #expect(LauncherService.webAddress("hello") == nil)
        #expect(LauncherService.webAddress("") == nil)
    }
}

@MainActor
struct FocusTimerTests {
    @Test func shortRunsAreNotRecorded() {
        let timer = FocusTimerService(persists: false)
        timer.start(label: "듣기 2주차")
        #expect(timer.isRunning)
        #expect(timer.stop(now: .now.addingTimeInterval(10)) == nil)
        #expect(timer.runs.isEmpty)
        #expect(!timer.isRunning)
    }

    @Test func totalsAddUpPerLabelForToday() {
        let timer = FocusTimerService(persists: false)
        timer.start(label: "듣기 2주차")
        _ = timer.stop(now: .now.addingTimeInterval(600))
        timer.start(label: "듣기 2주차")
        _ = timer.stop(now: .now.addingTimeInterval(300))
        timer.start(label: "NotchAI")
        _ = timer.stop(now: .now.addingTimeInterval(120))

        let totals = timer.todayTotals
        #expect(totals.first?.label == "듣기 2주차")
        #expect(totals.first?.seconds == 900)
        #expect(timer.todaySeconds == 1020)
        #expect(FocusTimerService.duration(900) == "15분")
        #expect(FocusTimerService.clock(3723) == "1:02:03")
    }

    @Test func anEmptyLabelBecomesTheDefaultOne() {
        let timer = FocusTimerService(persists: false)
        timer.start(label: "   ")
        #expect(timer.label == "집중")
    }
}

struct ShortTimeTests {
    @Test func agesReadAsKorean() {
        let now = Date.now
        #expect(ShortTime.ago(now, now: now) == "방금")
        #expect(ShortTime.ago(now.addingTimeInterval(-600), now: now) == "10분 전")
        #expect(ShortTime.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3시간 전")
        #expect(ShortTime.ago(now.addingTimeInterval(-2 * 86_400), now: now) == "2일 전")
    }
}

struct CodexStateTests {
    @Test func helperThreadsAreNotSessions() {
        #expect(CodexStateReader.isUserThread(source: "vscode", threadSource: "user"))
        #expect(!CodexStateReader.isUserThread(source: #"{"subagent":{"other":"guardian"}}"#,
                                               threadSource: "guardian_review"))
        // `codex exec` runs (including the notch's own usage refresh) are not open threads.
        #expect(!CodexStateReader.isUserThread(source: "exec", threadSource: "user"))
    }

    @Test func aThreadIsNamedByItsNameThenItsSummary() {
        func thread(name: String, title: String, cwd: String = "/Users/x/Documents/DEAN") -> CodexStateReader.Thread {
            CodexStateReader.Thread(id: "1", name: name, title: title, cwd: cwd, source: "vscode",
                                    threadSource: "user", updatedAt: .now, rolloutPath: "")
        }
        #expect(CodexStateReader.title(of: thread(name: "검고담임 광고영상 기획 수립", title: "무시됨"))
                == "검고담임 광고영상 기획 수립")
        #expect(CodexStateReader.title(of: thread(name: "", title: "2주차 PPT 정리")) == "2주차 PPT 정리")
        // Some threads carry a whole prompt as their title; the folder is the better name.
        #expect(CodexStateReader.title(of: thread(name: "", title: String(repeating: "가", count: 300))) == "DEAN")
    }

    @Test func theNewestNumberedDatabaseWins() {
        #expect(CodexStateReader.version(of: "state_5.sqlite", prefix: "state") == 5)
        #expect(CodexStateReader.version(of: "thread_history_1.sqlite", prefix: "thread_history") == 1)
    }
}

struct IdleNoteTests {
    @Test func openSessionsComeBeforeUsage() {
        #expect(IdleNote.note(waiting: 3, weeklyPercent: 75) == "대기 3")
        #expect(IdleNote.note(waiting: 0, weeklyPercent: 75) == "주간 75%")
        // Nothing open and no reading yet: the wing stays empty rather than saying "Idle".
        #expect(IdleNote.note(waiting: 0, weeklyPercent: nil) == nil)
    }
}
