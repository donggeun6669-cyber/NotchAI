import AVFoundation
import CryptoKit
import Foundation
import Observation

/// Free, on-device transcription of finished recordings with whisper.cpp — the same model and
/// flags as DEAN's `transcribe.sh`, so a friend's 강의녹음 gets the transcripts this Mac gets.
///
/// Nothing leaves the Mac and no paid API is involved. The whisper-cli binary ships inside the app
/// (scripts/build-whisper.sh); the 1.6GB model is downloaded once, then checked against its
/// published SHA-256 before it is used. Output lands next to the recording as `.txt` and `.srt`.
@MainActor
@Observable
final class Transcriber: NSObject {
    enum ModelState: Equatable {
        case missing
        case downloading(received: Int64)
        case verifying
        case ready
        case failed(String)
    }

    enum Job: Equatable {
        case preparing
        case transcribing(percent: Int)
        case failed(String)
    }

    nonisolated static let modelName = "ggml-large-v3-turbo.bin"
    nonisolated static let modelBytes: Int64 = 1_624_555_275
    /// Hugging Face's LFS hash for the file (x-linked-etag), identical to this Mac's copy.
    nonisolated static let modelSHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    nonisolated static let modelRemote = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    nonisolated static let language = "ko"
    /// Below this mean loudness the audio is lifted before whisper hears it (transcribe.sh: -25 dB).
    nonisolated static let quietDecibels = -25.0

    private(set) var modelState: ModelState = .missing
    private(set) var jobs: [URL: Job] = [:]
    /// Files whose transcript was written during this run, for the UI to switch to "자막".
    private(set) var finished: Set<URL> = []

    let folder: URL
    var modelURL: URL { folder.appendingPathComponent("models").appendingPathComponent(Self.modelName) }
    private var partialURL: URL { modelURL.appendingPathExtension("partial") }
    /// Bundled by 강의녹음 only; NotchAI keeps using the DEAN script. Tests pass their own.
    var whisperURL: URL? { whisperOverride ?? Bundle.main.url(forResource: "whisper-cli", withExtension: nil) }
    private let whisperOverride: URL?
    var isAvailable: Bool { whisperURL != nil }
    var isBusy: Bool { !jobs.values.filter { if case .failed = $0 { false } else { true } }.isEmpty }

    private var session: URLSession?
    private var download: URLSessionDownloadTask?
    private var processes: [URL: Process] = [:]

    init(folder: URL = RecorderService.folder, whisper: URL? = nil) {
        self.folder = folder
        whisperOverride = whisper
        super.init()
        refreshModel()
    }

    // MARK: - Model

    /// A file of exactly the published size counts as present; its hash was checked when it was
    /// downloaded (or it came from DEAN's own setup), and hashing 1.6GB at every launch is waste.
    func refreshModel() {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? nil
        modelState = size == Self.modelBytes ? .ready : .missing
    }

    func downloadModel() {
        guard download == nil else { return }
        try? FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: Self.modelRemote)
        self.session = session
        download = task
        modelState = .downloading(received: 0)
        task.resume()
    }

    func cancelDownload() {
        download?.cancel()
        download = nil
        session?.invalidateAndCancel()
        session = nil
        modelState = .missing
    }

    /// Runs after the download lands in `partialURL`: size, then SHA-256, then the real name.
    private func verifyDownloadedModel() {
        modelState = .verifying
        let partial = partialURL, final = modelURL
        Task {
            let ok = await Task.detached { Self.fileMatches(partial, bytes: Self.modelBytes, sha256: Self.modelSHA256) }.value
            if ok {
                try? FileManager.default.removeItem(at: final)
                do {
                    try FileManager.default.moveItem(at: partial, to: final)
                    modelState = .ready
                } catch {
                    modelState = .failed("모델 파일을 옮기지 못했습니다: \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: partial)
                modelState = .failed("받은 모델이 손상되었습니다. 다시 받아 주세요.")
            }
        }
    }

    nonisolated static func fileMatches(_ url: URL, bytes: Int64, sha256: String) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size == bytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize()) == sha256
    }

    nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Transcribing

    nonisolated static func transcriptURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("txt")
    }

    func hasTranscript(_ recording: URL) -> Bool {
        finished.contains(recording)
            || FileManager.default.fileExists(atPath: Self.transcriptURL(for: recording).path)
    }

    func job(for recording: URL) -> Job? { jobs[recording] }

    /// One at a time: whisper already uses the whole GPU (or every CPU core on Intel).
    func transcribe(_ recording: URL) {
        guard !isBusy, modelState == .ready, let whisper = whisperURL else { return }
        jobs[recording] = .preparing
        finished.remove(recording)
        let model = modelURL
        Task {
            let wav = FileManager.default.temporaryDirectory
                .appendingPathComponent("강의녹음-\(UUID().uuidString).wav")
            do {
                try await Task.detached(priority: .utility) {
                    _ = try Self.prepareAudio(from: recording, to: wav)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: wav)
                jobs[recording] = .failed("소리를 읽지 못했습니다: \(error.localizedDescription)")
                return
            }
            guard jobs[recording] == .preparing else {   // cancelled while preparing
                try? FileManager.default.removeItem(at: wav)
                return
            }
            run(whisper: whisper, model: model, wav: wav, recording: recording)
        }
    }

    func cancel(_ recording: URL) {
        processes[recording]?.terminate()
        processes[recording] = nil
        jobs[recording] = nil
    }

    private func run(whisper: URL, model: URL, wav: URL, recording: URL) {
        let base = recording.deletingPathExtension()
        let process = Process()
        process.executableURL = whisper
        process.arguments = Self.arguments(model: model, wav: wav, base: base,
                                           threads: min(8, ProcessInfo.processInfo.activeProcessorCount))
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let percent = text.split(separator: "\n").compactMap({ Self.progress(fromLine: String($0)) }).last
            else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.processes[recording] != nil else { return }
                    self.jobs[recording] = .transcribing(percent: percent)
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            errors.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    try? FileManager.default.removeItem(at: wav)
                    guard let self, self.processes.removeValue(forKey: recording) != nil else { return }
                    let transcript = Self.transcriptURL(for: recording)
                    let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path)[.size] as? Int) ?? 0
                    if status == 0, size > 0 {
                        self.jobs[recording] = nil
                        self.finished.insert(recording)
                    } else {
                        self.jobs[recording] = .failed("전사에 실패했습니다 (코드 \(status)).")
                    }
                }
            }
        }
        do {
            try process.run()
            processes[recording] = process
            jobs[recording] = .transcribing(percent: 0)
        } catch {
            try? FileManager.default.removeItem(at: wav)
            jobs[recording] = .failed("전사 프로그램을 시작하지 못했습니다: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure helpers (tested)

    /// The DEAN transcribe.sh flags. -mc 0 stops whisper carrying the previous sentence as context
    /// (the direct cause of its repetition loops), -sns suppresses non-speech tokens.
    nonisolated static func arguments(model: URL, wav: URL, base: URL, threads: Int) -> [String] {
        ["-m", model.path, "-f", wav.path, "-l", language, "-t", String(threads),
         "-mc", "0", "-sns", "-et", "2.8",
         "--output-txt", "--output-srt", "--output-file", base.path, "--print-progress"]
    }

    /// "whisper_print_progress_callback: progress =  45%" → 45.
    nonisolated static func progress(fromLine line: String) -> Int? {
        guard let range = line.range(of: "progress =") else { return nil }
        let digits = line[range.upperBound...].filter(\.isNumber)
        return Int(digits).map { min(100, max(0, $0)) }
    }

    // MARK: - Audio preparation

    /// Writes the 16kHz mono 16-bit WAV whisper reads, and returns the recording's mean loudness.
    ///
    /// Stands in for transcribe.sh's ffmpeg chain, which a friend's Mac does not have: an 80Hz
    /// high-pass always, and for quiet recordings (mean under -25 dB) a slow, windowed gain that
    /// lifts speech toward 90% peak by at most 10× without pumping up long silences. Simply
    /// turning a quiet file up is what sent whisper into repeating one sentence for 47 minutes
    /// (2026-09-21). ffmpeg's FFT denoiser is not reproduced; -sns covers part of its job.
    @discardableResult
    nonisolated static func prepareAudio(from input: URL, to output: URL) throws -> Double {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let frame = 3_200   // 200ms, as dynaudnorm f=200

        // Pass 1: loudness and per-frame peaks after the high-pass.
        var filter = HighPass()
        var peaks: [Float] = []
        var peak: Float = 0, inFrame = 0
        var sumSquares = 0.0, count = 0
        try decode(input, to: format) { samples in
            for raw in samples {
                sumSquares += Double(raw * raw)
                count += 1
                peak = max(peak, abs(filter.process(raw)))
                inFrame += 1
                if inFrame == frame { peaks.append(peak); peak = 0; inFrame = 0 }
            }
        }
        if inFrame > 0 { peaks.append(peak) }
        let meanDecibels = count > 0 && sumSquares > 0 ? 10 * log10(sumSquares / Double(count)) : -160
        let gains = meanDecibels < quietDecibels ? frameGains(peaks: peaks) : []

        // Pass 2: filter, apply the gain curve, write.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        filter = HighPass()
        var position = 0
        try decode(input, to: format) { samples in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            let out = buffer.floatChannelData![0]
            for (i, raw) in samples.enumerated() {
                var value = filter.process(raw)
                if !gains.isEmpty { value *= gain(at: position, gains: gains, frame: frame) }
                out[i] = max(-1, min(1, value))
                position += 1
            }
            try? file.write(from: buffer)
        }
        return meanDecibels
    }

    /// Target gain per 200ms frame: reach 90% peak, never more than 10×, and take the minimum over
    /// ±7 frames so a loud word is never clipped. Near-silent frames do not vote — otherwise every
    /// pause would pin the speech around it at 1× — and a stretch with no speech nearby stays at
    /// 1×, so long silences are not turned into amplified hiss. Then smooth.
    nonisolated static func frameGains(peaks: [Float], maxGain: Float = 10, silence: Float = 0.0018) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        let raw: [Float?] = peaks.map { $0 < silence ? nil : min(maxGain, 0.9 / $0) }
        let radius = 7
        let floored = raw.indices.map { i in
            raw[max(0, i - radius)...min(raw.count - 1, i + radius)].compactMap { $0 }.min() ?? 1
        }
        return floored.indices.map { i in
            let window = floored[max(0, i - radius)...min(floored.count - 1, i + radius)]
            return window.reduce(0, +) / Float(window.count)
        }
    }

    /// Linear between frame centres, so the gain never steps audibly.
    nonisolated static func gain(at sample: Int, gains: [Float], frame: Int) -> Float {
        let exact = (Double(sample) - Double(frame) / 2) / Double(frame)
        let lower = max(0, min(gains.count - 1, Int(exact.rounded(.down))))
        let upper = min(gains.count - 1, lower + 1)
        let t = Float(max(0, min(1, exact - Double(lower))))
        return gains[lower] * (1 - t) + gains[upper] * t
    }

    /// Decodes any file AVFoundation reads into `format`, handing over one chunk at a time so a
    /// two-hour lecture never sits in memory whole.
    nonisolated static func decode(_ url: URL, to format: AVAudioFormat,
                                   _ body: ([Float]) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var finished = false
        var readError: Error?
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if finished || file.framePosition >= file.length {
                    finished = true
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input)
                } catch {
                    readError = error
                    finished = true
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? CocoaError(.fileReadCorruptFile) }
            if output.frameLength > 0 {
                try body(Array(UnsafeBufferPointer(start: output.floatChannelData![0],
                                                   count: Int(output.frameLength))))
            }
            if status == .endOfStream { break }
        }
    }

    /// Second-order Butterworth high-pass at 80Hz for 16kHz audio (RBJ cookbook).
    struct HighPass {
        private let b0, b1, b2, a1, a2: Float
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(cutoff: Double = 80, sampleRate: Double = 16_000) {
            let w0 = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w0) / (2 * 0.7071)
            let cosw = cos(w0)
            let a0 = 1 + alpha
            b0 = Float((1 + cosw) / 2 / a0)
            b1 = Float(-(1 + cosw) / a0)
            b2 = b0
            a1 = Float(-2 * cosw / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}

extension Transcriber: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            modelState = .downloading(received: totalBytesWritten)
        }
    }

    /// The temporary file disappears when this returns, so it is moved aside right here.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            try? FileManager.default.removeItem(at: partialURL)
            let moved = (try? FileManager.default.moveItem(at: location, to: partialURL)) != nil
            download = nil
            session.finishTasksAndInvalidate()
            self.session = nil
            if status == 200, moved {
                verifyDownloadedModel()
            } else {
                modelState = .failed("모델을 받지 못했습니다 (HTTP \(status)).")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        MainActor.assumeIsolated {
            download = nil
            self.session = nil
            modelState = .failed("모델을 받지 못했습니다: \(error.localizedDescription)")
        }
    }
}
