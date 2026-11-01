import AVFoundation
import Foundation

// The three things push-to-talk touches outside the app: the WebSocket, the microphone and the
// speakers. Each is a small protocol so the tests replace it — the tests never open the real
// microphone and never play a sound (동근님 may be in class).

// MARK: WebSocket

enum VoiceSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

protocol VoiceSocket: AnyObject, Sendable {
    /// Sends one message. Callers send one at a time so the order holds (`start` before audio).
    func send(_ message: VoiceSocketMessage) async throws
    /// The next message; throws once the connection is gone.
    func receive() async throws -> VoiceSocketMessage
    func close()
}

/// The real connection: URLSession's WebSocket task.
final class URLSessionVoiceSocket: VoiceSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
    }

    func send(_ message: VoiceSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> VoiceSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}

// MARK: Microphone

enum VoiceMicPermission: Equatable {
    case allowed
    case notAsked
    case denied
}

@MainActor
protocol VoiceMic: AnyObject {
    /// Opens the input; `frames` gets 16 kHz mono little-endian int16 audio, on any thread.
    func start(frames: @escaping @Sendable (Data) -> Void) throws
    /// Closes the input at once (the orange microphone dot goes out).
    func stop()
}

enum VoiceMicError: Error {
    case noInput
    case noConverter
}

/// Mic audio in whatever format the device gives → 16 kHz mono int16. Keeps the resampler's state
/// between buffers, so a stream of small buffers comes out as one continuous signal.
final class VoicePCMConverter: @unchecked Sendable {
    let output: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()

    init?(from input: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(JarvisVoiceWire.sampleRate),
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.output = output
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}

/// The real microphone: a fresh AVAudioEngine per press, stopped on release, so the input is open
/// only while 동근님 holds the key or the light.
@MainActor
final class EngineVoiceMic: VoiceMic {
    private var engine: AVAudioEngine?

    static var permission: VoiceMicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Shows macOS's own question. 동근님 answers it; nothing here answers for him.
    static func askPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start(frames: @escaping @Sendable (Data) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceMicError.noInput }
        guard let converter = VoicePCMConverter(from: format) else { throw VoiceMicError.noConverter }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(converter, frames))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Built outside the main actor: the audio thread calls it.
    nonisolated private static func tap(_ converter: VoicePCMConverter,
                                        _ frames: @escaping @Sendable (Data) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let data = converter.convert(buffer) { frames(data) }
        }
    }
}

// MARK: Speakers

@MainActor
protocol VoicePlayer: AnyObject {
    /// Plays one chunk after whatever is queued; `done` runs on the main actor once it has been
    /// heard. Never called for chunks thrown away by `stop()`.
    func play(_ samples: [Int16], sampleRate: Int, done: @escaping @MainActor @Sendable () -> Void)
    /// Drops everything queued and playing, now.
    func stop()
    /// Nothing more to play for a while: let go of the output device.
    func shutdown()
}

/// The real player: AVAudioEngine with one player node, float mono at the server's rate (the mixer
/// converts to the device). `offline` renders without any device — only the tests use it.
@MainActor
final class EngineVoicePlayer: VoicePlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var rate: Double = 0
    private var generation = 0
    private let offline: Bool

    init(offline: Bool = false) {
        self.offline = offline
    }

    nonisolated static func floats(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[0][index] = Float(sample) / 32768 }
        return buffer
    }

    /// The engine for `sampleRate`, started. Rebuilt only when the rate changes.
    private func ready(_ sampleRate: Int) throws -> (AVAudioPlayerNode, AVAudioFormat) {
        let wanted = Double(sampleRate)
        if let engine, let node, rate == wanted {
            if !engine.isRunning { try engine.start() }
            if !node.isPlaying { node.play() }
            return (node, node.outputFormat(forBus: 0))
        }
        shutdown()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: wanted, channels: 1) else {
            throw VoiceMicError.noConverter
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        engine.prepare()
        try engine.start()
        node.play()
        self.engine = engine
        self.node = node
        rate = wanted
        return (node, format)
    }

    func play(_ samples: [Int16], sampleRate: Int, done: @escaping @MainActor @Sendable () -> Void) {
        guard let (node, format) = try? ready(sampleRate), let buffer = Self.floats(samples, format: format) else {
            done()
            return
        }
        node.scheduleBuffer(buffer, completionCallbackType: offline ? .dataRendered : .dataPlayedBack,
                            completionHandler: Self.finished(generation: generation, player: self, done: done))
    }

    nonisolated private static func finished(generation: Int, player: EngineVoicePlayer,
                                             done: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak player] _ in
            Task { @MainActor in
                guard let player, player.generation == generation else { return }
                done()
            }
        }
    }

    func stop() {
        generation += 1
        node?.stop()
        if node != nil, engine?.isRunning == true { node?.play() }
    }

    func shutdown() {
        generation += 1
        node?.stop()
        engine?.stop()
        engine = nil
        node = nil
        rate = 0
    }

    /// Tests: pulls `frames` of audio through the offline engine (no device involved).
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard offline, let engine,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else { return nil }
        var left = frames
        let total = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)
        while left > 0 {
            let status = try engine.renderOffline(min(left, buffer.frameCapacity), to: buffer)
            guard status == .success else { break }
            if let total, let source = buffer.floatChannelData, let target = total.floatChannelData {
                let start = Int(total.frameLength)
                for index in 0..<Int(buffer.frameLength) { target[0][start + index] = source[0][index] }
                total.frameLength += buffer.frameLength
            }
            left -= buffer.frameLength
        }
        return total
    }
}
