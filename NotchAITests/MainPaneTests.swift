import Foundation
import Testing
@testable import NotchAI

struct GitStatusTests {
    @Test func parsesOneLinePerRepository() {
        let output = """
        /Users/x/dev/GitHub/ReBridge\tparse-v3-safeguards\t2\t0\t0\t1758300000\t0
        /Users/x/dev/GitHub/Round_LLM\tmain\t4\t1\t1\t1758400000\t3
        broken line
        """
        let repos = GitStatusService.parse(output)
        #expect(repos.count == 2)
        #expect(repos[0].name == "ReBridge")
        #expect(repos[0].branch == "parse-v3-safeguards")
        #expect(repos[0].changed == 2)
        #expect(repos[0].hasUpstream == false)
        #expect(repos[1].ahead == 1)
        #expect(repos[1].untracked == 3)
        #expect(repos[1].lastCommit == Date(timeIntervalSince1970: 1_758_400_000))
    }

    @Test func aBranchWithoutARemoteStillNeedsAttention() {
        let clean = GitStatusService.Repo(path: "/a/b", branch: "main", changed: 0, untracked: 0,
                                          ahead: 0, hasUpstream: true, lastCommit: nil)
        let unpushedBranch = GitStatusService.Repo(path: "/a/c", branch: "feature", changed: 0, untracked: 0,
                                                   ahead: 0, hasUpstream: false, lastCommit: nil)
        let onlyNewFiles = GitStatusService.Repo(path: "/a/d", branch: "main", changed: 0, untracked: 1,
                                                 ahead: 0, hasUpstream: true, lastCommit: nil)
        #expect(!clean.needsAttention)
        #expect(unpushedBranch.needsAttention)
        #expect(onlyNewFiles.needsAttention)
        // Repositories that need attention come first.
        #expect(GitStatusService.order(unpushedBranch, clean))
    }
}

struct LauncherTests {
    @Test func remoteAddressesBecomeWebPages() {
        #expect(LauncherService.webURL(fromRemote: "git@github.com:donggeun6669-cyber/NotchAI.git")
                == "https://github.com/donggeun6669-cyber/NotchAI")
        #expect(LauncherService.webURL(fromRemote: "https://github.com/owner/repo.git")
                == "https://github.com/owner/repo")
        #expect(LauncherService.webURL(fromRemote: "/local/mirror.git") == nil)
    }

    @Test func nestedProjectsKeepTheirGroupInTheName() {
        let dean = LauncherService.deanURL.appendingPathComponent("03_PROJECTS")
        #expect(LauncherService.projectName(ofCodeLink: dean.appendingPathComponent("NotchAI/code")) == "NotchAI")
        #expect(LauncherService.projectName(ofCodeLink: dean.appendingPathComponent("JeparkENG/QM/code"))
                == "JeparkENG · QM")
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
struct ActivityLogTests {
    @Test func onlyOutcomesWorthRememberingAreKept() {
        let log = ActivityLogService(persists: false)
        log.record(.thinking, provider: .claude, title: "NotchAI")
        log.record(.toolStarted("Editing"), provider: .claude, title: "NotchAI")
        #expect(log.entries.isEmpty)

        log.record(.completed("정리했습니다"), provider: .claude, title: "NotchAI")
        log.record(.failed("Exited with code 1"), provider: .gpt, title: "광고영상")
        #expect(log.entries.count == 2)
        #expect(log.entries.first?.outcome == .failed)   // newest first
    }

    @Test func theSameEventArrivingTwiceIsStoredOnce() {
        let log = ActivityLogService(persists: false)
        let now = Date.now
        log.record(.completed("ok"), provider: .claude, title: "NotchAI", at: now)
        log.record(.completed("ok"), provider: .claude, title: "NotchAI", at: now.addingTimeInterval(2))
        #expect(log.entries.count == 1)

        log.record(.completed("ok"), provider: .claude, title: "NotchAI",
                   at: now.addingTimeInterval(ActivityLogService.duplicateWindow + 1))
        #expect(log.entries.count == 2)
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
