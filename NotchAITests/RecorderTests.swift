import AVFoundation
import Foundation
import Testing
@testable import NotchAI

struct RecorderTests {
    private func makeAudioFile(at url: URL) throws {
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frames) { data[frame] = 0.1 }
        }
        try file.write(from: buffer)
    }

    @Test func filesFollowTheNamingRuleTheScriptsAlreadyUse() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22,
                                                     hour: 19, minute: 4))!
        #expect(RecorderService.filename(at: date, calendar: calendar)
                == "2026-09-22_1904_녹음_강의실.m4a")
        #expect(RecorderService.filename(at: date, mode: .onlineSpeakers, calendar: calendar)
                == "2026-09-22_1904_녹음_온라인_스피커.m4a")
        #expect(RecorderService.filename(at: date, mode: .onlineAirPods, calendar: calendar)
                == "2026-09-22_1904_녹음_온라인_에어팟.m4a")
        #expect(RecorderService.filename(at: date, mode: .onlineMuted, calendar: calendar)
                == "2026-09-22_1904_녹음_온라인_무음.m4a")
    }

    @Test func midnightAndNoonDoNotCollapseIntoTheSameName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 0, minute: 5))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 12, minute: 5))!
        #expect(RecorderService.filename(at: midnight, calendar: calendar)
                == "2026-01-03_0005_녹음_강의실.m4a")
        #expect(RecorderService.filename(at: noon, calendar: calendar)
                == "2026-01-03_1205_녹음_강의실.m4a")
    }

    @Test func aDeadMicrophoneReadsAsZero() {
        // AVAudioRecorder reports -160 dB for true silence and 0 dB for a full-scale signal.
        #expect(RecorderService.level(fromDecibels: -160) == 0)
        #expect(RecorderService.level(fromDecibels: -50) == 0)
        #expect(RecorderService.level(fromDecibels: 0) == 1)
        #expect(RecorderService.level(fromDecibels: -25) == 0.5)
        // The pane warns below 0.02; ordinary room speech must sit well above it.
        #expect(RecorderService.level(fromDecibels: -30) > 0.02)
        #expect(RecorderService.level(fromDecibels: .infinity) == 0)
    }

    @Test func theClockRollsOverIntoHours() {
        #expect(RecorderService.clock(0) == "0:00")
        #expect(RecorderService.clock(59) == "0:59")
        #expect(RecorderService.clock(754) == "12:34")
        #expect(RecorderService.clock(3723) == "1:02:03")
        #expect(RecorderService.clock(-5) == "0:00")
    }

    @Test func durationsReadAsKorean() {
        #expect(RecorderService.duration(42) == "42초")
        #expect(RecorderService.duration(1380) == "23분")
        #expect(RecorderService.duration(3900) == "1시간 05분")
    }

    @Test func recordingsAreCompressedRatherThanRawPCM() {
        // Uncompressed capture wrote 29MB for 38 seconds — about 3GB for a two-hour lecture.
        let settings = RecorderService.audioSettings()
        #expect(settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect((settings[AVEncoderBitRateKey] as? Int ?? 0) <= 128_000)
    }

    @Test func aDisconnectedChannelDoesNotReadAsSound() {
        // A capture connection with nothing attached reports about -758 dB, far outside the
        // normal range. It must land on zero, not wrap into a full bar.
        #expect(RecorderService.level(fromDecibels: -758.6) == 0)
    }

    @Test func theStartupCheckHappensLongBeforeALectureIsLost() {
        #expect(RecorderService.startupCheckSeconds <= 5)
        #expect(RecorderService.silenceAlarmSeconds <= 60)
        #expect(RecorderService.deadLevel > 0)
    }

    @MainActor
    @Test func onlyM4AFilesAreListedAndNewestComesFirst() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Written oldest first so creation dates order the same way.
        try makeAudioFile(at: folder.appendingPathComponent("2026-09-20_1000_녹음.m4a"))
        try makeAudioFile(at: folder.appendingPathComponent("2026-09-21_1000_녹음.m4a"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("메모.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("2026-09-21_1000_녹음.srt"))

        let recorder = RecorderService(folder: folder)
        #expect(recorder.recents.count == 2)
        #expect(recorder.recents.allSatisfy { $0.url.pathExtension == "m4a" })
        #expect(recorder.recents.first?.startedAt ?? .distantPast
                >= recorder.recents.last?.startedAt ?? .distantFuture)
    }

    @MainActor
    @Test func aRecorderThatNeverStartedStopsWithoutAFile() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)")
        let recorder = RecorderService(folder: folder)
        #expect(recorder.isRunning == false)
        #expect(recorder.stop() == nil)
        #expect(recorder.recents.isEmpty)
    }

    @Test func aMisclickIsShorterThanAnythingWorthKeeping() {
        #expect(RecorderService.minimumSeconds > 0)
        #expect(RecorderService.minimumSeconds < 10)
    }

    @Test func eachModeKnowsWhichDeviceItNeeds() {
        #expect(RecorderService.Mode.classroom.usesMicrophone)
        #expect(!RecorderService.Mode.classroom.usesLoopback)
        #expect(!RecorderService.Mode.onlineSpeakers.usesMicrophone)
        #expect(RecorderService.Mode.onlineSpeakers.usesLoopback)
        #expect(!RecorderService.Mode.onlineAirPods.usesMicrophone)
        #expect(RecorderService.Mode.onlineAirPods.usesLoopback)
        // Muted: Mac sound only, and nothing played in the room — so no mic and no speakers needed.
        #expect(!RecorderService.Mode.onlineMuted.usesMicrophone)
        #expect(RecorderService.Mode.onlineMuted.usesLoopback)
        #expect(!RecorderService.Mode.onlineMuted.playsAloud)
        #expect(RecorderService.Mode.onlineSpeakers.playsAloud)
        #expect(RecorderService.Mode.onlineAirPods.playsAloud)
    }

    @Test func everyModeHasALabelAndAnExplanation() {
        for mode in RecorderService.Mode.allCases {
            #expect(!mode.label.isEmpty)
            #expect(!mode.explanation.isEmpty)
            #expect(!mode.symbol.isEmpty)
        }
    }

    @MainActor
    @Test func theLoopbackDeviceIsNeverOfferedAsAMicrophone() {
        // "맥 소리" is a mode, not a microphone the user picks from the menu.
        let recorder = RecorderService(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)"))
        #expect(!recorder.microphones.contains {
            $0.name.localizedCaseInsensitiveContains(AudioDevices.loopbackNeedle)
        })
        #expect(!recorder.microphones.contains { $0.name.hasPrefix(AudioDevices.aggregatePrefix) })
    }

    @MainActor
    @Test func aMissingLoopbackOnlyBlocksTheModesThatNeedIt() {
        let recorder = RecorderService(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)"))
        recorder.mode = .classroom
        #expect(recorder.isLoopbackMissing == false)
        let installed = AudioDevices.loopback() != nil
        recorder.mode = .onlineSpeakers
        #expect(recorder.isLoopbackMissing == !installed)
    }

    @MainActor
    @Test func theMutedPresetNeverWaitsForSpeakersOrAirPods() {
        let recorder = RecorderService(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)"))
        recorder.mode = .onlineMuted
        #expect(recorder.listeningDevice == nil)
        #expect(recorder.isListeningDeviceMissing == false)
        #expect(recorder.readinessTrouble == (AudioDevices.loopback() == nil ? .noLoopback : nil))
    }

    @Test func recoveryFilesAreClearlyMarkedAndNeverOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("lecture.m4a")
        let first = RecorderService.recoveryURL(for: original)
        #expect(first.lastPathComponent == "lecture_확인필요.m4a")
        try Data().write(to: first)
        #expect(RecorderService.recoveryURL(for: original).lastPathComponent
                == "lecture_확인필요_2.m4a")
    }
}
