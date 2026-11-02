import Foundation
import SwiftUI
import Testing
@testable import NotchAI

@MainActor
struct NotchFeaturesTests {
    /// 「자주 가는 사이트 정도는 써. 그 외엔 잘 안 씀」 (2026-11-01).
    @Test func onlyTheSitesStartShown() {
        let features = NotchFeatures(defaults: nil)
        #expect(features.enabled == [.launcher])
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
        #expect(reopened.enabled == [.timer, .music, .launcher])
        reopened.set(.timer, false)
        reopened.set(.launcher, false)   // switched off stays off
        #expect(NotchFeatures(defaults: defaults).enabled == [.music])
    }

    @Test func theCalendarAloneOpensTheLeftColumn() {
        let features = NotchFeatures(defaults: nil)
        features.set(.agents, true)
        #expect(!features.hasLeftColumn)
        features.set(.calendar, true)
        #expect(features.hasLeftColumn)
    }
}

@MainActor
struct PanelLayoutTests {
    /// 「노치 화면 아까처럼 더 크게」: with Jarvis on the left, the panel has its old size.
    @Test func withJarvisThePanelIsTheOldSize() {
        let layout = AppModel.layout(features: NotchFeatures(defaults: nil), jarvis: true)
        #expect(layout.body == AppModel.panelSize)
        #expect(layout.body == CGSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.expandedBodyHeight))
        #expect(layout.narrowWing == NotchGeometry.compactWingWidth)
    }

    @Test func withoutJarvisOnlyTheRightColumnRemains() {
        let features = NotchFeatures(defaults: nil)
        let sites = AppModel.layout(features: features, jarvis: false)
        #expect(sites.body.width < AppModel.panelSize.width)
        features.set(.launcher, false)
        let recorderOnly = AppModel.layout(features: features, jarvis: false)
        #expect(recorderOnly.body.height < sites.body.height)
        features.set(.calendar, true)
        #expect(AppModel.layout(features: features, jarvis: false).body == AppModel.panelSize)
    }

    @Test func theCharactersWidenTheWings() {
        let features = NotchFeatures(defaults: nil)
        features.set(.agents, true)
        let layout = AppModel.layout(features: features, jarvis: true)
        #expect(layout.narrowWing > NotchGeometry.compactWingWidth)
        #expect(layout.wideWing > layout.narrowWing)
        #expect(layout.clockWing > layout.narrowWing)
        #expect(layout.clockWing < layout.wideWing)
    }

    /// 「오른쪽에 온도 안 가리게」: a recording's wings are narrower than the wings for words.
    @Test func aRecordingAloneUsesTheClockWing() {
        let macBookPro14 = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         safeAreaTop: 32, leftAuxiliaryWidth: 665, rightAuxiliaryWidth: 662,
                                         menuBarHeight: 32)
        let model = NotchViewModel(geometry: macBookPro14)
        #expect(model.currentSize == macBookPro14.collapsedSize)
        #expect(model.currentWing == NotchGeometry.wingWidth)

        model.isClock = { true }
        #expect(model.currentSize == macBookPro14.clockCollapsedSize)
        #expect(model.currentWing == NotchGeometry.clockWingWidth)
        #expect(macBookPro14.clockCollapsedSize.width < macBookPro14.collapsedSize.width)
        // The mouse only opens the notch over what is drawn.
        let cut = macBookPro14.hitRect(expanded: false)
        let wingPoint = CGPoint(x: cut.maxX - 5, y: cut.midY)
        #expect(!macBookPro14.hitRect(expanded: false, clock: true).contains(wingPoint))

        // Nothing to say beats the clock wing.
        model.isCompact = { true }
        #expect(model.currentSize == macBookPro14.compactCollapsedSize)
        #expect(model.currentWing == NotchGeometry.compactWingWidth)
    }

    /// The strip clips, so the longest things a recording's wings hold must fit them.
    @Test func theClockWingHoldsTheRecordersLongestWords() throws {
        func width(_ mark: RecordingMark) throws -> CGFloat {
            let renderer = ImageRenderer(content: RecordingMarkView(mark: mark, narrow: false))
            return try #require(renderer.nsImage).size.width
        }
        let wing = NotchGeometry.clockWingWidth
        #expect(try width(.recording(seconds: 35_999, alarm: true)) <= wing)
        #expect(try width(.checking(secondsLeft: 3)) <= wing)
        #expect(try width(.finishing) <= wing)
        for words in ["녹음 안 됨", "권한 없음", "저장 밀림", "파일 확인", "녹음 실패"] {
            #expect(try width(.failed(words)) <= wing)
        }

        let meter = ImageRenderer(content: LevelMeter(level: 1))
        let meterWidth = try #require(meter.nsImage).size.width
        #expect(meterWidth + 5 + JarvisOrbLayout.holdTarget <= wing)
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
