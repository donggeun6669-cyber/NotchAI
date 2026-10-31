import Foundation
import Testing
@testable import NotchAI

@MainActor
struct NotchFeaturesTests {
    @Test func everythingButTheRecorderStartsHidden() {
        let features = NotchFeatures(defaults: nil)
        #expect(features.enabled.isEmpty)
        #expect(features.deskTabs.isEmpty)
        #expect(!features.hasLeftColumn)
    }

    @Test func switchesAreRememberedAndReported() throws {
        let suite = "NotchFeaturesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let features = NotchFeatures(defaults: defaults)
        var heard: [(NotchFeatures.Feature, Bool)] = []
        features.onChange = { heard.append(($0, $1)) }
        features.set(.timer, true)
        features.set(.music, true)
        features.set(.music, true)   // already on: nothing to report
        #expect(heard.map(\.0) == [.timer, .music])
        #expect(features.deskTabs == [.music, .focus])   // the desk's own order
        #expect(features.hasLeftColumn)

        let reopened = NotchFeatures(defaults: defaults)
        #expect(reopened.enabled == [.timer, .music])
        reopened.set(.timer, false)
        #expect(NotchFeatures(defaults: defaults).enabled == [.music])
    }

    @Test func theCalendarAloneOpensTheLeftColumn() {
        let features = NotchFeatures(defaults: nil)
        features.set(.launcher, true)
        features.set(.agents, true)
        #expect(!features.hasLeftColumn)
        features.set(.calendar, true)
        #expect(features.hasLeftColumn)
    }
}

@MainActor
struct PanelLayoutTests {
    @Test func theRecorderAloneIsSmallerThanTheOldPanel() {
        let layout = AppModel.layout(features: NotchFeatures(defaults: nil), jarvis: false)
        #expect(layout.body.width < NotchGeometry.minExpandedWidth)
        #expect(layout.body.height < NotchGeometry.expandedBodyHeight)
        #expect(layout.narrowWing == NotchGeometry.compactWingWidth)
    }

    @Test func eachPartAddsItsOwnRoom() {
        let features = NotchFeatures(defaults: nil)
        let alone = AppModel.layout(features: features, jarvis: false)
        let withJarvis = AppModel.layout(features: features, jarvis: true)
        #expect(withJarvis.body.height > alone.body.height)
        #expect(withJarvis.body.width == alone.body.width)

        features.set(.agents, true)
        let withAgents = AppModel.layout(features: features, jarvis: true)
        #expect(withAgents.body.height > withJarvis.body.height)
        #expect(withAgents.narrowWing > alone.narrowWing)   // the characters join the wings

        features.set(.calendar, true)
        let withCalendar = AppModel.layout(features: features, jarvis: true)
        #expect(withCalendar.body.width > withAgents.body.width)
        #expect(withCalendar.body.height >= AppModel.leftColumnMinHeight)
    }

    @Test func geometryFollowsTheLayout() {
        let layout = NotchLayout(narrowWing: 32, wideWing: 80, body: CGSize(width: 372, height: 300))
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     safeAreaTop: 32, leftAuxiliaryWidth: 665, rightAuxiliaryWidth: 662,
                                     menuBarHeight: 32, layout: layout)
        #expect(geometry.compactCollapsedSize.width == CGFloat(185 + 64))
        #expect(geometry.collapsedSize.width == CGFloat(185 + 160))
        #expect(geometry.expandedSize == CGSize(width: 372, height: 332))
    }
}

struct RecordingMarkTests {
    private func mark(_ phase: RecorderService.Phase, elapsed: TimeInterval = 0, alarm: Bool = false,
                      trouble: RecorderService.Trouble? = nil, attention: Bool = false) -> RecordingMark {
        RecordingMark.make(phase: phase, elapsed: elapsed, alarm: alarm, trouble: trouble, needsAttention: attention)
    }

    @Test func quietWhenNothingHappens() {
        #expect(mark(.idle) == .ready)
        // A warning that was dismissed is not shown again.
        #expect(mark(.idle, trouble: .deadInput, attention: false) == .ready)
    }

    @Test func checkCountsDown() {
        #expect(mark(.checkingInput, elapsed: 0.2) == .checking(secondsLeft: 3))
        #expect(mark(.checkingInput, elapsed: 2.5) == .checking(secondsLeft: 1))
    }

    @Test func recordingShowsItsClockAndAlarm() {
        #expect(mark(.recording, elapsed: 754.6) == .recording(seconds: 754, alarm: false))
        #expect(mark(.recording, elapsed: 60, alarm: true) == .recording(seconds: 60, alarm: true))
        #expect(mark(.recording).showsLevel)
    }

    /// The 2026-10-03 and 2026-10-07 first attempts: the 3-second check heard nothing.
    @Test func aSilentFirstAttemptStaysInSight() {
        #expect(mark(.idle, trouble: .deadInput, attention: true) == .failed("녹음 안 됨"))
        #expect(mark(.idle, trouble: .deadSystemAudio, attention: true) == .failed("녹음 안 됨"))
        #expect(mark(.idle, trouble: .denied, attention: true) == .failed("권한 없음"))
        // No trouble but the alarm is up: the finished file failed its check.
        #expect(mark(.idle, alarm: true, attention: true) == .failed("파일 확인"))
        #expect(!mark(.idle, trouble: .deadInput, attention: true).showsLevel)
    }
}

@MainActor
struct RecorderAttentionTests {
    @Test func nothingToSeeOnAFreshRecorder() {
        let recorder = RecorderService(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(!recorder.needsAttention)
        recorder.dismissTrouble()
        #expect(!recorder.needsAttention)
    }
}
