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
