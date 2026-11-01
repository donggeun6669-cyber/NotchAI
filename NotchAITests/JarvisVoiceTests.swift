import AVFoundation
import Foundation
import Network
import Testing
@testable import NotchAI

// Push-to-talk (2026-11-01). Nothing here opens the real microphone or plays a sound: the
// microphone and the speakers are fakes, the player's real engine renders offline (no device),
// and the server is a fake — in memory, or a tiny WebSocket server on 127.0.0.1.

// MARK: Fakes

@MainActor
private final class FakeMic: VoiceMic {
    private(set) var running = false
    private(set) var starts = 0
    var fails = false
    private var frames: (@Sendable (Data) -> Void)?

    func start(frames: @escaping @Sendable (Data) -> Void) throws {
        if fails { throw VoiceMicError.noInput }
        running = true
        starts += 1
        self.frames = frames
    }

    func stop() { running = false }

    /// What the audio thread would hand over.
    func speak(_ data: Data) { frames?(data) }
}

@MainActor
private final class FakePlayer: VoicePlayer {
    struct Item {
        var samples: [Int16]
        var rate: Int
        var done: @MainActor @Sendable () -> Void
    }

    private(set) var queued: [Item] = []
    private(set) var played: [[Int16]] = []
    private(set) var stops = 0
    private(set) var shutdowns = 0

    func play(_ samples: [Int16], sampleRate: Int, done: @escaping @MainActor @Sendable () -> Void) {
        queued.append(Item(samples: samples, rate: sampleRate, done: done))
        played.append(samples)
    }

    func stop() {
        stops += 1
        queued.removeAll()
    }

    func shutdown() {
        shutdowns += 1
        queued.removeAll()
    }

    /// The next chunk has been heard.
    func finishNext() {
        guard !queued.isEmpty else { return }
        queued.removeFirst().done()
    }
}

private final class FakeSocket: VoiceSocket, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var _sent: [VoiceSocketMessage] = []
    private var _closed = false
    private let stream: AsyncThrowingStream<VoiceSocketMessage, Error>
    private let input: AsyncThrowingStream<VoiceSocketMessage, Error>.Continuation
    nonisolated(unsafe) private var iterator: AsyncThrowingStream<VoiceSocketMessage, Error>.AsyncIterator

    init(url: URL) {
        self.url = url
        (stream, input) = AsyncThrowingStream<VoiceSocketMessage, Error>.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    var sent: [VoiceSocketMessage] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }
    var texts: [String] {
        sent.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }
    var audioBytes: Int {
        sent.reduce(0) { if case .data(let data) = $1 { $0 + data.count } else { $0 } }
    }

    func send(_ message: VoiceSocketMessage) async throws {
        lock.withLock { _sent.append(message) }
    }

    func receive() async throws -> VoiceSocketMessage {
        guard let next = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return next
    }

    func close() {
        lock.withLock { _closed = true }
        input.finish()
    }

    /// The server says something.
    func push(_ message: VoiceSocketMessage) { input.yield(message) }
    func push(_ json: String) { input.yield(.text(json)) }
    /// The connection drops.
    func drop() { input.finish(throwing: URLError(.networkConnectionLost)) }
}

/// The chat API, for the conversation a call joins.
private actor FakeChatAPI: JarvisTransport {
    private(set) var created = 0

    func get(_ url: URL) async throws -> (Data, Int) {
        (Data(#"{"state":"idle"}"#.utf8), 200)
    }

    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int) {
        if method == "POST", url.path == "/api/conversations" {
            created += 1
            return (Data(#"{"id":"c-made","title":"노치"}"#.utf8), 201)
        }
        return (Data(), 404)
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_793_500_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private final class Rig {
    let clock = Clock()
    let mic = FakeMic()
    let player = FakePlayer()
    let api = FakeChatAPI()
    let defaults: UserDefaults
    let jarvis: JarvisService
    let chat: JarvisChat
    var recording = false
    var permission = VoiceMicPermission.allowed
    var asked = 0
    var modifiersDown = true
    private(set) var sockets: [FakeSocket] = []
    var voice: JarvisVoice!

    init(storedConversation: String? = "c-today") {
        let suite = "JarvisVoiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let storedConversation { defaults.set(JarvisChat.day() + "|" + storedConversation, forKey: JarvisChat.storeKey) }
        jarvis = JarvisService(transport: api, address: "https://desk.example.ts.net")
        chat = JarvisChat(jarvis: jarvis, defaults: defaults)
        voice = JarvisVoice(jarvis: jarvis, chat: chat, isRecording: { [unowned self] in recording },
                            mic: mic, player: player,
                            connect: { [unowned self] url in
                                let socket = FakeSocket(url: url)
                                sockets.append(socket)
                                return socket
                            },
                            permission: { [unowned self] in permission },
                            askPermission: { [unowned self] in asked += 1 },
                            modifiersDown: { [unowned self] in modifiersDown },
                            clock: { [unowned self] in clock.now }, ticksItself: false)
    }

    var socket: FakeSocket { sockets.last! }

    func tick() { voice.tick(now: clock.now) }

    /// Press, wait for `start`, have the server say ready.
    func connect(conversation: String = "c-today") async {
        voice.press(.pointer)
        await eventually { self.sockets.last?.texts.first?.contains("start") == true }
        socket.push(#"{"type":"ready","conv_id":"\#(conversation)","title":"노치","model":"haiku","sample_rate_in":16000,"sample_rate_out":44100}"#)
        await eventually { self.voice.isConnected }
    }
}

/// Lets queued main-actor work run until `condition` holds (or a second passes).
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func chunk(turn: UInt32, seq: UInt32, samples: [Int16]) -> Data {
    var data = Data()
    for value in [turn, seq] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    return data + JarvisVoiceWire.pcm(samples)
}

// MARK: The wire

struct JarvisVoiceWireTests {
    @Test func everyEventTheServerSends() {
        #expect(JarvisVoiceEvent.parse(#"{"type":"ready","conv_id":"c1","title":"통화","model":"haiku","sample_rate_in":16000,"sample_rate_out":44100}"#)
                == .ready(conversation: "c1", sampleRateOut: 44100, title: "통화"))
        #expect(JarvisVoiceEvent.parse(#"{"type":"state","state":"thinking","user_speaking":false}"#)
                == .state("thinking", userSpeaking: false))
        #expect(JarvisVoiceEvent.parse(#"{"type":"end_of_turn","turn":3,"reason":"smart_turn","eos_to_commit_ms":210}"#)
                == .endOfTurn(turn: 3))
        #expect(JarvisVoiceEvent.parse(#"{"type":"heard","turn":3,"text":"내일 일정 알려 줘","timings":{}}"#)
                == .heard(turn: 3, text: "내일 일정 알려 줘"))
        #expect(JarvisVoiceEvent.parse(#"{"type":"heard","turn":4,"text":"","dropped":true,"raw":"감사합니다."}"#)
                == .heard(turn: 4, text: ""))
        #expect(JarvisVoiceEvent.parse(#"{"type":"status","turn":3,"text":"캘린더 읽는 중"}"#) == .status(turn: 3, text: "캘린더 읽는 중"))
        #expect(JarvisVoiceEvent.parse(#"{"type":"reply_delta","turn":3,"text":"내일은 "}"#) == .replyDelta(turn: 3, text: "내일은 "))
        #expect(JarvisVoiceEvent.parse(#"{"type":"reply_done","turn":3,"text":"내일은 비어 있어요.","timings":{}}"#)
                == .replyDone(turn: 3, text: "내일은 비어 있어요."))
        #expect(JarvisVoiceEvent.parse(#"{"type":"interrupt","turn":3,"reason":"barge_in","detect_ms":170}"#)
                == .interrupt(turn: 3, reason: "barge_in"))
        #expect(JarvisVoiceEvent.parse(#"{"type":"ignored","reason":"too_short"}"#) == .ignored("too_short"))
        #expect(JarvisVoiceEvent.parse(#"{"type":"error","turn":3,"message":"두뇌 연결 오류"}"#) == .error("두뇌 연결 오류", turn: 3))
        #expect(JarvisVoiceEvent.parse(#"{"type":"say","turn":3,"seq":0,"text":"내일은","kind":"text"}"#) == .other("say"))
    }

    @Test func brokenEventsAreNotGuessed() {
        #expect(JarvisVoiceEvent.parse("not json") == nil)
        #expect(JarvisVoiceEvent.parse(#"{"turn":1}"#) == nil)
        #expect(JarvisVoiceEvent.parse(#"{"type":"heard","text":"턴 번호 없음"}"#) == nil)
        #expect(JarvisVoiceEvent.parse(#"{"type":"ready"}"#) == nil)
        // A ready without the output rate falls back to the server's usual 44.1 kHz.
        #expect(JarvisVoiceEvent.parse(#"{"type":"ready","conv_id":"c1"}"#)
                == .ready(conversation: "c1", sampleRateOut: 44100, title: nil))
    }

    @Test func audioChunksAreLittleEndian() throws {
        let parsed = try #require(JarvisVoiceChunk.parse(chunk(turn: 7, seq: 258, samples: [0, 1, -1, 32767, -32768])))
        #expect(parsed == JarvisVoiceChunk(turn: 7, seq: 258, samples: [0, 1, -1, 32767, -32768]))
        #expect(JarvisVoiceChunk.parse(Data([1, 0, 0])) == nil)               // shorter than the header
        #expect(JarvisVoiceChunk.parse(Data(count: 9)) == nil)                 // half a sample
        #expect(JarvisVoiceChunk.parse(Data(count: 8))?.samples == [])
    }

    @Test func sameAddressWithTheVoicePath() {
        #expect(JarvisVoiceWire.url(base: URL(string: "https://desk.example.ts.net")!)?.absoluteString
                == "wss://desk.example.ts.net/voice/ws")
        #expect(JarvisVoiceWire.url(base: URL(string: "http://127.0.0.1:8766")!)?.absoluteString == "ws://127.0.0.1:8766/voice/ws")
        #expect(JarvisVoiceWire.url(base: URL(string: "https://host.ts.net/jarvis/")!)?.absoluteString
                == "wss://host.ts.net/jarvis/voice/ws")
        #expect(JarvisVoiceWire.url(base: URL(string: "ftp://host")!) == nil)
    }

    @Test func whatTheNotchSends() throws {
        let start = try #require(try JSONSerialization.jsonObject(with: Data(JarvisVoiceWire.start(conversation: "c1").utf8)) as? [String: String])
        #expect(start == ["type": "start", "conv_id": "c1"])
        #expect(JarvisVoiceWire.start(conversation: nil) == #"{"type":"start"}"#)
        #expect(JarvisVoiceWire.playback(turn: 2, started: true) == #"{"state":"started","turn":2,"type":"playback"}"#)
        #expect(JarvisVoiceWire.playback(turn: 2, started: false) == #"{"state":"ended","turn":2,"type":"playback"}"#)
        #expect(JarvisVoiceWire.hangup == #"{"type":"hangup"}"#)
        #expect(JarvisVoiceWire.pcm([1, -2]) == Data([0x01, 0x00, 0xFE, 0xFF]))
        // 20 ms frames of 16 kHz int16: 640 bytes each, all zero.
        #expect(JarvisVoiceWire.silence(frames: 3) == Data(count: 1920))
    }
}

// MARK: Audio conversion (no device)

struct JarvisVoiceAudioTests {
    /// 48 kHz stereo float (what a Mac microphone gives) → 16 kHz mono int16, buffer after buffer.
    @Test func microphoneAudioBecomes16kMono() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = try #require(VoicePCMConverter(from: input))
        var total = Data()
        for block in 0..<20 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800))
            buffer.frameLength = 4800
            for frame in 0..<4800 {
                let t = Double(block * 4800 + frame) / 48_000
                let value = Float(0.5 * sin(2 * .pi * 440 * t))
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            total += try #require(converter.convert(buffer))
        }
        // Two seconds in → two seconds out (32 000 samples), short only by the resampler's latency
        // (about 15 ms, which stays inside it for the next buffer: nothing is lost).
        let samples = total.count / 2
        #expect(samples <= 32_000 && 32_000 - samples < 400, "got \(samples) samples")
        let values = total.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let peak = values.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 12_000 && peak < 20_000)      // 0.5 of full scale, not doubled by the downmix
    }

    @Test func playerSamplesAreScaledFloats() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(EngineVoicePlayer.floats([0, 16384, -32768], format: format))
        #expect(buffer.frameLength == 3)
        #expect(buffer.floatChannelData![0][1] == 0.5 && buffer.floatChannelData![0][2] == -1)
        #expect(EngineVoicePlayer.floats([], format: format) == nil)
    }

    /// The real player engine, rendered offline: no speaker is involved. The chunk comes out and its
    /// completion runs; after `stop` a dropped chunk's completion never runs.
    @MainActor
    @Test func realPlayerRendersOfflineAndReportsTheEnd() async throws {
        let player = EngineVoicePlayer(offline: true)
        let count = Counter()
        let tone = (0..<4410).map { Int16(10_000 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
        player.play(tone, sampleRate: 44_100) { count.value += 1 }
        let rendered = try #require(try player.renderOffline(frames: 8820))
        let channel = rendered.floatChannelData![0]
        // The 0.1 s tone comes out once, whole (where in the 0.2 s the engine starts it varies).
        let heard = (0..<8820).filter { abs(channel[$0]) > 0.01 }.count
        let peak = (0..<8820).map { abs(channel[$0]) }.max() ?? 0
        #expect(heard > 4000 && heard <= 4410, "\(heard) loud samples")
        #expect(peak > 0.2 && peak < 0.35)
        await eventually { count.value == 1 }
        #expect(count.value == 1)

        player.play(tone, sampleRate: 44_100) { count.value += 10 }
        player.stop()
        _ = try player.renderOffline(frames: 8820)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(count.value == 1)
        player.shutdown()
    }
}

// MARK: Push-to-talk

@MainActor
struct JarvisVoiceTests {
    @Test func pressOpensTheMicAndJoinsTodaysConversation() async {
        let rig = Rig()
        rig.voice.press(.pointer)
        #expect(rig.mic.running)
        #expect(rig.voice.phase == .holding)                  // shown at once, before the server
        #expect(rig.voice.showsInStrip)
        // Words spoken while the connection opens are kept and sent after `start`, in order.
        rig.mic.speak(Data([1, 1]))
        await eventually { rig.socket.texts.count == 1 && rig.socket.audioBytes == 2 }
        #expect(rig.socket.url.absoluteString == "wss://desk.example.ts.net/voice/ws")
        let first = rig.socket.sent.first
        #expect(first == .text(JarvisVoiceWire.start(conversation: "c-today")))
        #expect(rig.socket.sent.dropFirst().first == .data(Data([1, 1])))
        rig.mic.speak(Data([2, 2]))
        await eventually { rig.socket.audioBytes == 4 }
        #expect(rig.socket.sent.last == .data(Data([2, 2])))
    }

    @Test func noConversationYetMakesTheDaysOne() async {
        let rig = Rig(storedConversation: nil)
        rig.voice.press(.pointer)
        await eventually { rig.socket.texts.first != nil }
        #expect(rig.socket.texts.first == JarvisVoiceWire.start(conversation: "c-made"))
        #expect(await rig.api.created == 1)
        #expect(JarvisChat.reusable(stored: rig.defaults.string(forKey: JarvisChat.storeKey), today: JarvisChat.day()) == "c-made")
    }

    @Test func letGoStopsTheMicAndSendsSilenceInstead() async {
        let rig = Rig()
        await rig.connect()
        rig.clock.advance(1.5)
        rig.voice.release(.pointer)
        #expect(!rig.mic.running)                             // the orange dot goes out at once
        #expect(rig.voice.phase == .waiting)
        let before = rig.socket.audioBytes
        rig.clock.advance(0.1)
        rig.tick()
        await eventually { rig.socket.audioBytes > before }
        #expect(rig.socket.audioBytes - before == 5 * 640)    // 100 ms of generated 20 ms frames
        rig.mic.speak(Data([9, 9]))                             // a stray buffer from a later press? no: same press
        rig.clock.advance(0.05)
        rig.tick()
        await eventually { rig.socket.audioBytes >= before + 5 * 640 + 2 + 2 * 640 }
        #expect(rig.socket.audioBytes == before + 5 * 640 + 2 + 2 * 640)
        #expect(!rig.socket.closed)                            // still open to hear the answer
    }

    @Test func aClickIsNotSpeech() async {
        let rig = Rig()
        rig.voice.press(.pointer)
        rig.clock.advance(0.1)
        rig.voice.release(.pointer)
        #expect(!rig.mic.running)
        #expect(rig.voice.phase == .idle)
        #expect(rig.voice.notice?.short == "꾹 누른 채 말해요")
        rig.clock.advance(JarvisVoice.noticeSeconds + 0.1)
        rig.tick()
        #expect(rig.voice.notice == nil)
    }

    @Test func neverDuringARecording() async {
        let rig = Rig()
        rig.recording = true
        rig.voice.press(.hotKey)
        #expect(rig.mic.starts == 0)
        #expect(rig.sockets.isEmpty)
        #expect(rig.voice.notice?.text == "녹음 중에는 말 걸기를 쉬어요")
        #expect(rig.voice.notice?.short == "녹음 중엔 쉬어요")
        #expect(rig.voice.phase == .idle)
    }

    @Test func aRecordingThatStartsEndsTheCall() async {
        let rig = Rig()
        await rig.connect()
        rig.socket.push(.data(chunk(turn: 1, seq: 0, samples: [1, 2, 3])))
        await eventually { rig.player.queued.count == 1 }
        rig.recording = true
        rig.clock.advance(0.02)
        rig.tick()
        #expect(!rig.mic.running)
        #expect(rig.player.queued.isEmpty)                     // nothing more is played into the lecture
        #expect(rig.voice.phase == .idle)
        await eventually { rig.socket.closed }
        #expect(rig.socket.texts.last == JarvisVoiceWire.hangup)
    }

    @Test func playsTheAnswerAndSaysWhenItStartsAndEnds() async {
        let rig = Rig()
        await rig.connect()
        rig.clock.advance(1)
        rig.voice.release(.pointer)
        rig.socket.push(#"{"type":"end_of_turn","turn":1,"reason":"smart_turn"}"#)
        rig.socket.push(#"{"type":"heard","turn":1,"text":"내일 일정 알려 줘"}"#)
        rig.socket.push(#"{"type":"reply_delta","turn":1,"text":"내일은 "}"#)
        rig.socket.push(.data(chunk(turn: 1, seq: 0, samples: [10, 20])))
        rig.socket.push(.data(chunk(turn: 1, seq: 1, samples: [30])))
        rig.socket.push(#"{"type":"reply_done","turn":1,"text":"내일은 비어 있어요."}"#)
        await eventually { rig.player.queued.count == 2 && rig.chat.lines.count == 2 && rig.chat.lines.last?.state == .done }
        #expect(rig.player.played == [[10, 20], [30]])
        #expect(rig.player.queued.first?.rate == 44100)
        #expect(rig.voice.phase == .speaking)
        #expect(rig.socket.texts.contains(JarvisVoiceWire.playback(turn: 1, started: true)))
        #expect(rig.chat.lines.map(\.text) == ["내일 일정 알려 줘", "내일은 비어 있어요."])
        #expect(rig.chat.conversationID == "c-today")

        rig.player.finishNext()
        #expect(!rig.socket.texts.contains(JarvisVoiceWire.playback(turn: 1, started: false)))
        rig.player.finishNext()
        await eventually { rig.socket.texts.contains(JarvisVoiceWire.playback(turn: 1, started: false)) }
        #expect(rig.voice.phase == .idle)
        #expect(rig.player.shutdowns >= 1)                     // the speakers are let go
    }

    @Test func talkingOverJarvisCutsItOffAtOnce() async {
        let rig = Rig()
        await rig.connect()
        rig.socket.push(#"{"type":"heard","turn":1,"text":"길게 설명해 줘"}"#)
        rig.socket.push(#"{"type":"reply_delta","turn":1,"text":"그러니까"}"#)
        rig.socket.push(.data(chunk(turn: 1, seq: 0, samples: [1])))
        rig.socket.push(.data(chunk(turn: 1, seq: 1, samples: [2])))
        await eventually { rig.player.queued.count == 2 }
        rig.socket.push(#"{"type":"interrupt","turn":1,"reason":"barge_in","detect_ms":170}"#)
        await eventually { rig.player.stops == 1 }
        #expect(rig.player.queued.isEmpty)
        #expect(rig.socket.texts.last == JarvisVoiceWire.playback(turn: 1, started: false))
        #expect(rig.chat.lines.last?.state == .stopped)
        // Late audio of the cut turn is not played.
        rig.socket.push(.data(chunk(turn: 1, seq: 2, samples: [3])))
        rig.socket.push(#"{"type":"state","state":"listening","user_speaking":true}"#)
        await eventually { rig.voice.serverState == "listening" }
        #expect(rig.player.played.count == 2)
    }

    @Test func aContinuedTurnLeavesOneLine() async {
        let rig = Rig()
        await rig.connect()
        rig.socket.push(#"{"type":"heard","turn":1,"text":"그러니까 내일 오전에"}"#)
        rig.socket.push(#"{"type":"interrupt","turn":1,"reason":"continued"}"#)
        rig.socket.push(#"{"type":"heard","turn":2,"text":"그러니까 내일 오전에 수업 있어?"}"#)
        await eventually { rig.chat.lines.count == 1 && rig.chat.lines.first?.text.hasSuffix("있어?") == true }
        #expect(rig.chat.lines.map(\.text) == ["그러니까 내일 오전에 수업 있어?"])
    }

    @Test func theServersConversationIsAdopted() async {
        let rig = Rig()
        await rig.connect(conversation: "c-other")      // today's was gone on the server
        #expect(rig.chat.conversationID == "c-other")
        #expect(JarvisChat.reusable(stored: rig.defaults.string(forKey: JarvisChat.storeKey), today: JarvisChat.day()) == "c-other")
    }

    @Test func twoQuietMinutesHangUpAndTheNextPressReconnects() async {
        let rig = Rig()
        await rig.connect()
        rig.clock.advance(1)
        rig.voice.release(.pointer)
        rig.socket.push(#"{"type":"heard","turn":1,"text":"고마워"}"#)
        rig.socket.push(#"{"type":"reply_done","turn":1,"text":"네"}"#)
        await eventually { rig.voice.phase == .idle }
        rig.clock.advance(JarvisVoice.idleTimeout - 1)
        rig.tick()
        #expect(!rig.socket.closed)
        rig.clock.advance(2)
        rig.tick()
        await eventually { rig.socket.closed }
        #expect(rig.socket.texts.last == JarvisVoiceWire.hangup)
        #expect(!rig.voice.isConnected)
        #expect(!rig.chat.voiceActive)

        rig.voice.press(.pointer)
        await eventually { rig.sockets.count == 2 && rig.socket.texts.count == 1 }
        #expect(rig.socket.texts.first == JarvisVoiceWire.start(conversation: "c-today"))
    }

    @Test func nothingHeardSaysSo() async {
        let rig = Rig()
        await rig.connect()
        rig.clock.advance(1)
        rig.voice.release(.pointer)
        rig.socket.push(#"{"type":"end_of_turn","turn":1}"#)
        rig.socket.push(#"{"type":"heard","turn":1,"text":"","dropped":true}"#)
        await eventually { rig.voice.notice != nil }
        #expect(rig.voice.phase == .idle)
        #expect(rig.voice.notice?.short == "못 들었어요")
    }

    @Test func aTurnEndedWhileHeldDoesNotLeaveItThinking() async {
        let rig = Rig()
        await rig.connect()
        // The server ended the turn and answered while the key was still down.
        rig.socket.push(#"{"type":"heard","turn":1,"text":"안녕"}"#)
        rig.socket.push(#"{"type":"reply_done","turn":1,"text":"안녕하세요"}"#)
        await eventually { rig.chat.lines.count == 2 }
        rig.clock.advance(2)
        rig.voice.release(.pointer)
        #expect(rig.voice.phase == .waiting)
        rig.clock.advance(JarvisVoice.turnEndGrace + 0.1)
        rig.tick()
        #expect(rig.voice.phase == .idle)
    }

    @Test func aMissedKeyReleaseStillClosesTheMic() async {
        let rig = Rig()
        rig.voice.press(.hotKey)
        rig.clock.advance(1)
        rig.tick()
        #expect(rig.mic.running)
        rig.modifiersDown = false                              // ⌥ is up, but no release came
        rig.clock.advance(0.1)
        rig.tick()
        #expect(rig.mic.running)
        rig.clock.advance(JarvisVoice.modifierGrace + 0.01)
        rig.tick()
        #expect(!rig.mic.running)

        // And nobody holds for a minute: that too ends it.
        rig.modifiersDown = true
        rig.voice.press(.pointer)
        rig.clock.advance(JarvisVoice.longestHold + 1)
        rig.tick()
        #expect(!rig.mic.running)
    }

    @Test func microphonePermissionIsAskedNotAnswered() async {
        let rig = Rig()
        rig.permission = .notAsked
        rig.voice.press(.pointer)
        #expect(rig.asked == 1)
        #expect(rig.mic.starts == 0)
        #expect(rig.voice.notice?.short == "허용을 눌러 주세요")
        rig.permission = .denied
        rig.clock.advance(5)
        rig.voice.press(.pointer)
        #expect(rig.mic.starts == 0)
        #expect(rig.voice.notice?.short == "마이크 권한 없음")
    }

    @Test func aDroppedConnectionWhileHoldingReconnectsOnce() async {
        let rig = Rig()
        await rig.connect()
        rig.socket.drop()
        await eventually { rig.sockets.count == 2 }
        #expect(rig.mic.running)                                // still listening, on the new connection
        await eventually { rig.socket.texts.first?.contains("start") == true }
        rig.socket.drop()
        await eventually { !rig.mic.running }
        #expect(rig.sockets.count == 2)
        #expect(rig.voice.notice?.short == "연결 끊김")
    }

    @Test func theLightFollowsTheCall() async {
        let rig = Rig()
        #expect(rig.voice.orbState(over: .idle) == .idle)
        rig.voice.press(.pointer)
        #expect(rig.voice.orbState(over: .offline) == .listening)
        rig.clock.advance(1)
        rig.voice.release(.pointer)
        #expect(rig.voice.orbState(over: .idle) == .thinking)
    }
}

// MARK: A real WebSocket (127.0.0.1)

/// A minimal WebSocket server: answers `start` with `ready` and one audio chunk, keeps what it got.
private final class TinyVoiceServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TinyVoiceServer")
    private let lock = NSLock()
    private var _got: [VoiceSocketMessage] = []
    private var connections: [NWConnection] = []

    var got: [VoiceSocketMessage] { lock.withLock { _got } }
    var port: UInt16? { listener.port?.rawValue }

    init() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let data else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let message: VoiceSocketMessage = metadata?.opcode == .text ? .text(String(decoding: data, as: UTF8.self)) : .data(data)
            self.lock.withLock { self._got.append(message) }
            if case .text(let text) = message, text.contains(#""type":"start""#) {
                self.send(.text(#"{"type":"ready","conv_id":"c-test","sample_rate_out":44100}"#), on: connection)
                self.send(.data(chunk(turn: 1, seq: 0, samples: [5, -5])), on: connection)
            }
            self.receive(on: connection)
        }
    }

    private func send(_ message: VoiceSocketMessage, on connection: NWConnection) {
        let (opcode, data): (NWProtocolWebSocket.Opcode, Data) = switch message {
        case .text(let text): (.text, Data(text.utf8))
        case .data(let data): (.binary, data)
        }
        let context = NWConnection.ContentContext(identifier: "m", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

struct JarvisVoiceSocketTests {
    @Test func theRealSocketTalksToAWebSocketServer() async throws {
        let server = try TinyVoiceServer()
        defer { server.stop() }
        for _ in 0..<200 where server.port == nil || server.port == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let port = try #require(server.port)
        let url = try #require(JarvisVoiceWire.url(base: URL(string: "http://127.0.0.1:\(port)")!))
        let socket = URLSessionVoiceSocket(url: url)
        try await socket.send(.text(JarvisVoiceWire.start(conversation: "c-test")))
        try await socket.send(.data(JarvisVoiceWire.silence(frames: 2)))
        let ready = try await socket.receive()
        let audio = try await socket.receive()
        #expect(ready == .text(#"{"type":"ready","conv_id":"c-test","sample_rate_out":44100}"#))
        if case .data(let data) = audio {
            #expect(JarvisVoiceChunk.parse(data) == JarvisVoiceChunk(turn: 1, seq: 0, samples: [5, -5]))
        } else {
            Issue.record("expected binary audio, got \(audio)")
        }
        for _ in 0..<200 where server.got.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(server.got == [.text(JarvisVoiceWire.start(conversation: "c-test")), .data(Data(count: 1280))])
        socket.close()
    }
}
