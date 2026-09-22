import AVFoundation
import Foundation
import Testing
@testable import NotchAI

/// The tests that would have caught 2026-09-22: a 69-minute file whose length matched the clock
/// exactly and which contained nothing at all.
struct RecordingCheckTests {
    // MARK: - Helpers

    /// Writes a real m4a of `seconds` at a given amplitude, so the check is exercised against
    /// an actual encoded file rather than a stub.
    private func makeFile(seconds: Double, amplitude: Float, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m4a")
        try? FileManager.default.removeItem(at: url)
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(rate * 0.5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "test", code: 1)
        }
        buffer.frameLength = frames
        // A 440 Hz tone, so the file holds real signal rather than a DC offset the encoder drops.
        if let data = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frames) {
                data[frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(rate))
            }
        }
        for _ in 0..<Int(seconds / 0.5) { try file.write(from: buffer) }
        return url
    }

    // MARK: - The failure that started this

    @Test func aFileOfTheRightLengthWithNoSoundIsNotAcceptable() throws {
        // This is the 2026-09-22 lecture in miniature: the clock and the file agree, and the
        // recording is worthless. Length alone must never read as success.
        let url = try makeFile(seconds: 4, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = RecordingCheck.measure(url: url, expectedSeconds: 4)
        #expect(check.problems.contains(.silent))
        #expect(check.isClean == false)
        #expect(check.fileSeconds >= 3)          // the length really is right
        #expect(check.meanDecibels <= RecordingCheck.silenceCeiling)
        #expect(check.summary.contains("소리가 하나도"))
    }

    @Test func anOrdinaryRecordingPasses() throws {
        let url = try makeFile(seconds: 4, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = RecordingCheck.measure(url: url, expectedSeconds: 4)
        #expect(check.isClean)
        #expect(check.problems.isEmpty)
        #expect(check.meanDecibels > RecordingCheck.quietCeiling)
        #expect(check.peakDecibels > -20)
        #expect(check.summary.contains("✅"))
    }

    @Test func aRecordingTooFaintToTranscribeIsFlagged() throws {
        let url = try makeFile(seconds: 4, amplitude: 0.0015)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = RecordingCheck.measure(url: url, expectedSeconds: 4)
        #expect(check.problems.contains(.tooQuiet))
        #expect(!check.problems.contains(.silent))
    }

    @Test func aFileShorterThanTheClockReportsTheGap() throws {
        // The 1교시 failure: recording ran on, the file stopped early.
        let url = try makeFile(seconds: 4, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = RecordingCheck.measure(url: url, expectedSeconds: 60)
        #expect(check.problems.contains { if case .truncated = $0 { true } else { false } })
        guard case .truncated(let missing)? = check.problems.first(where: {
            if case .truncated = $0 { return true } else { return false }
        }) else {
            Issue.record("truncated 문제가 없다"); return
        }
        #expect(missing >= 55)
        #expect(check.summary.contains("비었습니다"))
    }

    @Test func aSecondOrTwoOfEncoderTrimIsNotCalledTruncation() throws {
        let url = try makeFile(seconds: 4, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = RecordingCheck.measure(url: url, expectedSeconds: 5)
        #expect(!check.problems.contains { if case .truncated = $0 { true } else { false } })
    }

    @Test func aMissingFileIsUnreadableRatherThanSilent() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        let check = RecordingCheck.measure(url: url, expectedSeconds: 10)
        #expect(check.problems == [.unreadable])
        #expect(check.fileSeconds == 0)
    }

    // MARK: - Thresholds

    @Test func theSilenceThresholdSitsAboveWhatAnEmptyFileMeasures() {
        // The lost lecture measured -91 dB. Anything at or below that has to trip the check.
        #expect(RecordingCheck.silenceCeiling > -91)
        #expect(RecordingCheck.silenceCeiling < RecordingCheck.quietCeiling)
    }

    @Test func amplitudeConvertsToDecibelsWithAFloor() {
        #expect(RecordingCheck.decibels(from: 1) == 0)
        #expect(abs(RecordingCheck.decibels(from: 0.5) - -6.02) < 0.05)
        #expect(RecordingCheck.decibels(from: 0) == -160)
    }

    @Test func problemsReadAsPlainKorean() {
        #expect(RecordingCheck.Problem.silent.message.contains("소리가 하나도"))
        #expect(RecordingCheck.Problem.tooQuiet.message.contains("너무 작"))
        #expect(RecordingCheck.Problem.truncated(missingSeconds: 30).message.contains("30초"))
        #expect(RecordingCheck.Problem.unreadable.message.contains("읽을 수 없"))
    }
}
