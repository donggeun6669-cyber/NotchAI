import AVFoundation
import Foundation
import Testing
@testable import NotchAI

struct TranscriberTests {
    @Test func progressIsReadFromWhisperLines() {
        #expect(Transcriber.progress(fromLine: "whisper_print_progress_callback: progress =  45%") == 45)
        #expect(Transcriber.progress(fromLine: "whisper_print_progress_callback: progress = 100%") == 100)
        #expect(Transcriber.progress(fromLine: "whisper_init_with_params_no_state: use gpu = 1") == nil)
    }

    @Test func argumentsMatchTheDEANScript() {
        let args = Transcriber.arguments(model: URL(fileURLWithPath: "/m.bin"), wav: URL(fileURLWithPath: "/a.wav"),
                                         base: URL(fileURLWithPath: "/rec/lecture"), threads: 8)
        for flag in ["-mc", "0", "-sns", "-et", "2.8", "--output-txt", "--output-srt", "--print-progress"] {
            #expect(args.contains(flag))
        }
        #expect(args[args.firstIndex(of: "-l")! + 1] == "ko")
        #expect(args[args.firstIndex(of: "--output-file")! + 1] == "/rec/lecture")
    }

    @Test func transcriptSitsNextToTheRecording() {
        let url = URL(fileURLWithPath: "/r/2026-09-29_1200_녹음_강의실.m4a")
        #expect(Transcriber.transcriptURL(for: url).lastPathComponent == "2026-09-29_1200_녹음_강의실.txt")
    }

    @Test func loudFramesAreNeverPushedPastFullScaleAndSilenceIsLeftAlone() {
        let peaks: [Float] = Array(repeating: 0.0005, count: 20) + Array(repeating: 0.05, count: 20)
            + [0.6] + Array(repeating: 0.05, count: 20)
        let gains = Transcriber.frameGains(peaks: peaks)
        #expect(gains.count == peaks.count)
        #expect(gains.allSatisfy { $0 >= 1 && $0 <= 10 })
        #expect(gains[40] * 0.6 <= 0.9 + 0.0001)          // the loud word stays under 90%
        #expect(gains[2] < 1.01)                           // leading silence is not amplified
        #expect(gains[30] > 5)                             // quiet speech is lifted
    }

    @MainActor
    @Test func aBundledModelIsReadyWithoutADownload() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriberTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundled = folder.appendingPathComponent("\(Transcriber.bundledModelName).bin")

        // Nothing shipped and nothing downloaded: the download is offered.
        let without = Transcriber(folder: folder, bundledModel: bundled)
        #expect(without.modelState == .missing)

        try Data("model".utf8).write(to: bundled)
        let with = Transcriber(folder: folder, bundledModel: bundled)
        #expect(with.modelState == .ready)
        #expect(with.modelURL == bundled)
    }

    @Test func aWrongFileNeverPassesTheModelCheck() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        try Data("not a model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!Transcriber.fileMatches(url, bytes: 11, sha256: Transcriber.modelSHA256))
        #expect(Transcriber.fileMatches(url, bytes: 11,
                                        sha256: "c4e1b4c1d8a5a1f5b4b3c0a1f6e4f1b0b4c3c2a1d0e9f8a7b6c5d4e3f2a1b0c9") == false)
    }

    /// A quiet 44.1kHz stereo tone becomes 16kHz mono, keeps its length, and is lifted.
    @Test func quietRecordingsAreConvertedAndLifted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("quiet.caf"), output = dir.appendingPathComponent("out.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let seconds = 3
        do {   // the writer must be closed before the file is read back
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44_100 * seconds))!
            buffer.frameLength = buffer.frameCapacity
            for ch in 0..<2 {
                for i in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![ch][i] = 0.02 * sin(2 * .pi * 440 * Float(i) / 44_100)   // about -37 dB
                }
            }
            try file.write(from: buffer)
        }

        let mean = try Transcriber.prepareAudio(from: input, to: output)
        #expect(mean < Transcriber.quietDecibels)
        let result = try AVAudioFile(forReading: output)
        #expect(result.fileFormat.sampleRate == 16_000)
        #expect(result.fileFormat.channelCount == 1)
        #expect(abs(Double(result.length) - Double(16_000 * seconds)) < 400)
        let read = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length))!
        try result.read(into: read)
        let samples = UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength))
        let middlePeak = samples[16_000..<32_000].map(abs).max() ?? 0
        #expect(middlePeak > 0.1 && middlePeak <= 1)
    }
}
