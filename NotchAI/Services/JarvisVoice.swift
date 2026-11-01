import Foundation
import Observation

/// Push-to-talk with Jarvis (2026-11-01). Hold the Jarvis light (or the hold key) and talk; let go
/// and Jarvis answers aloud. The microphone is open only while held; after letting go the notch
/// sends generated silence so the server notices the end of the turn at once, and keeps the
/// connection to hear the answer. Two quiet minutes close it; the next press opens it again.
/// Voice and typed messages share the notch's conversation of the day.
///
/// Never while a lecture is being recorded: pressing then only says so, and a recording that starts
/// during a call ends the call (nothing may be played into, or taken from, a lecture).
@MainActor
@Observable
final class JarvisVoice {
    enum Phase: Equatable {
        case idle
        /// Held: the microphone is open. Shown at once, before the server says anything.
        case holding
        /// Let go; Jarvis is working out the answer.
        case waiting
        /// Jarvis's voice is playing.
        case speaking
    }

    enum Trigger: Equatable {
        case pointer
        case hotKey
    }

    struct Notice: Equatable {
        /// The sentence for the open notch.
        var text: String
        /// A few words for the strip beside the closed notch.
        var short: String
        var until: Date
    }

    // Defaults (DECISIONS 2026-11-01 7차). Each is one constant.
    /// Quiet this long (no press, nothing from the server, nothing playing) closes the connection.
    static let idleTimeout: TimeInterval = 120
    /// A press shorter than this was a click, not speech.
    static let shortPress: TimeInterval = 0.3
    /// Nobody holds a key this long on purpose: the release was missed.
    static let longestHold: TimeInterval = 60
    /// The hold key's modifier let go this long ago while its release never came: treat as let go.
    static let modifierGrace: TimeInterval = 0.3
    static let noticeSeconds: TimeInterval = 3
    /// After letting go, stop showing 「생각 중」 if the server says nothing for this long.
    static let replyPatience: TimeInterval = 45
    /// After letting go with nothing more to end (the server had already ended the turn while it was
    /// held), this much silence shows there is no new turn coming. The server ends one within 1.2 s.
    static let turnEndGrace: TimeInterval = 3
    /// Microphone audio kept while the connection opens (10 s).
    static let bufferLimit = JarvisVoiceWire.sampleRate * 2 * 10
    static let recordingNotice = Notice(text: "녹음 중에는 말 걸기를 쉬어요", short: "녹음 중엔 쉬어요", until: .distantPast)

    // MARK: What the notch shows

    private(set) var isHolding = false
    private(set) var isPlaying = false
    private(set) var awaitingReply = false
    /// The server's own word: listening · thinking · speaking · idle.
    private(set) var serverState: String?
    private(set) var isConnected = false
    private(set) var notice: Notice?

    var phase: Phase {
        if isHolding { return .holding }
        if isPlaying { return .speaking }
        if awaitingReply || serverState == "thinking" { return .waiting }
        return .idle
    }

    /// The strip beside the closed notch widens for this (like a recording's clock).
    var showsInStrip: Bool { phase != .idle || notice != nil }

    /// The light: what the call is doing, while it is doing something; otherwise Jarvis's own state.
    func orbState(over base: JarvisOrbState) -> JarvisOrbState {
        switch phase {
        case .holding: .listening
        case .waiting: .thinking
        case .speaking: .speaking
        case .idle: base
        }
    }

    // MARK: Parts

    @ObservationIgnored private let jarvis: JarvisService
    @ObservationIgnored private let chat: JarvisChat
    @ObservationIgnored private let isRecording: () -> Bool
    @ObservationIgnored private let mic: any VoiceMic
    @ObservationIgnored private let player: any VoicePlayer
    @ObservationIgnored private let connect: (URL) -> any VoiceSocket
    @ObservationIgnored private let permission: () -> VoiceMicPermission
    @ObservationIgnored private let askPermission: () -> Void
    /// Whether the hold key's modifiers are still down (the missed-release guard).
    @ObservationIgnored private let modifiersDown: () -> Bool
    @ObservationIgnored let clock: () -> Date
    /// Off in the tests, which call `tick` themselves.
    @ObservationIgnored private let ticksItself: Bool

    // MARK: Connection state

    /// The words between letting go and the server saying what it heard.
    private enum Utterance: Equatable {
        case none
        case released(Date)
        /// The server ended the turn (`end_of_turn`); the transcript is on its way.
        case ended
    }

    private struct TurnPlayback {
        var queued = 0
        var playing = false
        var dropped = false
        var replyDone = false
    }

    @ObservationIgnored private var socket: (any VoiceSocket)?
    @ObservationIgnored private var outbox: AsyncStream<VoiceSocketMessage>.Continuation?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Bumped for every connection; late events from an old one are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startSent = false
    @ObservationIgnored private var early: [Data] = []
    @ObservationIgnored private var earlyBytes = 0
    @ObservationIgnored private var sampleRateOut = JarvisVoiceWire.defaultRateOut
    @ObservationIgnored private var turns: [Int: TurnPlayback] = [:]
    @ObservationIgnored private var utterance = Utterance.none
    /// The chat lines of this connection are "voice-<session>-<turn>".
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var lastFromServer = Date.distantPast
    /// Silence has been sent up to here (nil while the microphone runs).
    @ObservationIgnored private var silenceUntil: Date?
    @ObservationIgnored private var heldSince: Date?
    @ObservationIgnored private var trigger: Trigger?
    @ObservationIgnored private var modifiersUpSince: Date?
    @ObservationIgnored private var micGeneration = 0
    @ObservationIgnored private var reconnectedThisPress = false
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(jarvis: JarvisService, chat: JarvisChat, isRecording: @escaping () -> Bool,
         mic: (any VoiceMic)? = nil, player: (any VoicePlayer)? = nil,
         connect: ((URL) -> any VoiceSocket)? = nil,
         permission: (() -> VoiceMicPermission)? = nil, askPermission: (() -> Void)? = nil,
         modifiersDown: @escaping () -> Bool = { true },
         clock: @escaping () -> Date = { .now }, ticksItself: Bool = true) {
        self.jarvis = jarvis
        self.chat = chat
        self.isRecording = isRecording
        self.mic = mic ?? EngineVoiceMic()
        self.player = player ?? EngineVoicePlayer()
        self.connect = connect ?? { URLSessionVoiceSocket(url: $0) }
        self.permission = permission ?? { EngineVoiceMic.permission }
        self.askPermission = askPermission ?? { EngineVoiceMic.askPermission() }
        self.modifiersDown = modifiersDown
        self.clock = clock
        self.ticksItself = ticksItself
    }

    // MARK: Press and release

    func press(_ trigger: Trigger) {
        let now = clock()
        guard !isHolding else { return }
        guard let base = jarvis.baseURL, JarvisVoiceWire.url(base: base) != nil else {
            say("Jarvis 주소를 먼저 넣어 주세요", short: "주소 없음", now: now)
            return
        }
        if isRecording() {
            say(Self.recordingNotice.text, short: Self.recordingNotice.short, now: now)
            return
        }
        switch permission() {
        case .allowed: break
        case .notAsked:
            askPermission()
            say("마이크 허용 창이 뜨면 「허용」을 눌러 주세요", short: "허용을 눌러 주세요", now: now)
            return
        case .denied:
            say("마이크 권한이 꺼져 있어요 · 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 NotchAI를 켜 주세요",
                short: "마이크 권한 없음", now: now)
            return
        }
        micGeneration += 1
        do {
            try mic.start(frames: Self.frameHandler(self, micGeneration))
        } catch {
            say("마이크를 열지 못했어요", short: "마이크 안 열림", now: now)
            return
        }
        isHolding = true
        heldSince = now
        self.trigger = trigger
        modifiersUpSince = nil
        reconnectedThisPress = false
        silenceUntil = nil
        notice = nil
        lastActivity = now
        ensureConnected(now: now)
        startTicking()
    }

    func release(_ trigger: Trigger? = nil) {
        let now = clock()
        guard isHolding else { return }
        mic.stop()
        isHolding = false
        self.trigger = nil
        lastActivity = now
        silenceUntil = now
        if let heldSince, now.timeIntervalSince(heldSince) < Self.shortPress {
            say("누르고 있는 동안 말하고, 다 말하면 떼세요", short: "꾹 누른 채 말해요", now: now)
        } else {
            utterance = .released(now)
            lastFromServer = now
        }
        heldSince = nil
        settle()
    }

    /// Nonisolated so the closure is not tied to the main actor: the audio thread calls it.
    nonisolated private static func frameHandler(_ voice: JarvisVoice, _ generation: Int) -> @Sendable (Data) -> Void {
        { [weak voice] data in
            Task { @MainActor in voice?.heard(mic: data, generation: generation) }
        }
    }

    private func heard(mic data: Data, generation: Int) {
        // Buffers from this press that arrive just after letting go are still 동근님's words.
        guard generation == micGeneration, socket != nil else { return }
        send(.data(data))
    }

    // MARK: Connection

    private func ensureConnected(now: Date) {
        guard socket == nil, let base = jarvis.baseURL, let url = JarvisVoiceWire.url(base: base) else { return }
        generation += 1
        session += 1
        let generation = generation
        let socket = connect(url)
        self.socket = socket
        startSent = false
        early = []
        earlyBytes = 0
        turns = [:]
        lastFromServer = now

        let (stream, continuation) = AsyncStream<VoiceSocketMessage>.makeStream()
        outbox = continuation
        tasks.append(Task { [weak self] in
            do {
                for await message in stream { try await socket.send(message) }
                socket.close()     // hung up: the last message went out
            } catch {
                socket.close()
                self?.lost(generation)
            }
        })
        tasks.append(Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == generation else { return }
                    self.handle(message)
                }
            } catch {
                self?.lost(generation)
            }
        })
        tasks.append(Task { [weak self] in
            let conversation = await self?.chat.conversationForVoice()
            guard let self, self.generation == generation else { return }
            continuation.yield(.text(JarvisVoiceWire.start(conversation: conversation)))
            self.startSent = true
            for data in self.early { continuation.yield(.data(data)) }
            self.early = []
            self.earlyBytes = 0
        })
    }

    private func send(_ message: VoiceSocketMessage) {
        guard let outbox else { return }
        if !startSent, case .data(let data) = message {
            guard earlyBytes + data.count <= Self.bufferLimit else { return }
            early.append(data)
            earlyBytes += data.count
            return
        }
        outbox.yield(message)
    }

    /// The connection broke. If 동근님 is still holding, open it again once (same conversation).
    private func lost(_ generation: Int) {
        guard generation == self.generation else { return }
        let wasBusy = awaitingReply || isPlaying
        tearDown()
        let now = clock()
        if isHolding, !reconnectedThisPress {
            reconnectedThisPress = true
            ensureConnected(now: now)
            return
        }
        if isHolding {
            mic.stop()
            isHolding = false
            trigger = nil
        }
        if wasBusy || reconnectedThisPress {
            say("Jarvis 음성 연결이 끊겼어요 · 다시 누르면 새로 연결해요", short: "연결 끊김", now: now)
        }
    }

    /// Hang up politely: the server ends the call, then the socket closes.
    func hangUp() {
        guard socket != nil else { return }
        outbox?.yield(.text(JarvisVoiceWire.hangup))
        tearDown(polite: true)
    }

    private func tearDown(polite: Bool = false) {
        generation += 1
        if polite {
            outbox?.finish()   // the sender sends the hang-up, then closes the socket
            tasks.removeAll { _ in true }
        } else {
            tasks.forEach { $0.cancel() }
            tasks = []
            socket?.close()
        }
        outbox = nil
        socket = nil
        startSent = false
        early = []
        earlyBytes = 0
        player.shutdown()
        turns = [:]
        utterance = .none
        isPlaying = false
        isConnected = false
        awaitingReply = false
        serverState = nil
        silenceUntil = nil
        chat.voiceEnded()
    }

    // MARK: From the server

    private func handle(_ message: VoiceSocketMessage) {
        let now = clock()
        lastFromServer = now
        switch message {
        case .data(let data):
            guard let chunk = JarvisVoiceChunk.parse(data) else { return }
            lastActivity = now
            play(chunk)
        case .text(let text):
            guard let event = JarvisVoiceEvent.parse(text) else { return }
            handle(event, now: now)
        }
    }

    private func key(_ turn: Int) -> String { "voice-\(session)-\(turn)" }

    private func handle(_ event: JarvisVoiceEvent, now: Date) {
        switch event {
        case .ready(let conversation, let rate, _):
            isConnected = true
            sampleRateOut = rate
            chat.voiceStarted(conversation: conversation)
        case .state(let state, _):
            serverState = state
        case .endOfTurn:
            lastActivity = now
            if utterance != .none { utterance = .ended }
        case .heard(let turn, let text):
            lastActivity = now
            let waited = utterance != .none
            utterance = .none
            if text.isEmpty {
                settle()
                if waited, !awaitingReply { say("잘 못 들었어요 · 다시 말해 주세요", short: "못 들었어요", now: now) }
            } else {
                turns[turn, default: TurnPlayback()].replyDone = false
                chat.voiceHeard(key(turn), text: text)
                settle()
            }
        case .status(let turn, let text):
            lastActivity = now
            chat.voiceStatus(key(turn), text: text)
        case .replyDelta(let turn, let text):
            lastActivity = now
            chat.voiceReplyDelta(key(turn), text: text)
        case .replyDone(let turn, let text):
            lastActivity = now
            chat.voiceReplyDone(key(turn), text: text)
            turns[turn, default: TurnPlayback()].replyDone = true
            settle()
        case .interrupt(let turn, let reason):
            lastActivity = now
            drop(turn)
            chat.voiceInterrupted(key(turn), continued: reason == "continued")
        case .ignored:
            if utterance != .none { utterance = .none }
            settle()
        case .error(let message, _):
            lastActivity = now
            say(message, short: "문제가 생겼어요", now: now)
        case .other:
            break
        }
    }

    // MARK: Playing

    private func play(_ chunk: JarvisVoiceChunk) {
        var turn = turns[chunk.turn, default: TurnPlayback()]
        guard !turn.dropped, !chunk.samples.isEmpty else { return }
        turn.queued += 1
        let starts = !turn.playing
        turn.playing = true
        turns[chunk.turn] = turn
        isPlaying = true
        if starts { send(.text(JarvisVoiceWire.playback(turn: chunk.turn, started: true))) }
        let generation = generation
        let id = chunk.turn
        player.play(chunk.samples, sampleRate: sampleRateOut) { [weak self] in
            self?.played(turn: id, generation: generation)
        }
    }

    private func played(turn id: Int, generation: Int) {
        guard generation == self.generation, var turn = turns[id], !turn.dropped else { return }
        turn.queued = max(0, turn.queued - 1)
        if turn.queued == 0, turn.playing {
            turn.playing = false
            send(.text(JarvisVoiceWire.playback(turn: id, started: false)))
        }
        turns[id] = turn
        lastActivity = clock()
        settle()
    }

    /// Stop that turn's sound at once (the server heard 동근님 talk over it).
    private func drop(_ id: Int) {
        var turn = turns[id, default: TurnPlayback()]
        guard !turn.dropped else { return }
        let wasPlaying = turn.playing
        turn.dropped = true
        turn.playing = false
        turn.queued = 0
        turns[id] = turn
        player.stop()
        if wasPlaying { send(.text(JarvisVoiceWire.playback(turn: id, started: false))) }
        settle()
    }

    /// Works out playing / waiting from the turns, and lets go of the speakers when all is done.
    private func settle() {
        isPlaying = turns.values.contains { $0.playing }
        let unfinished = turns.values.contains { !$0.dropped && (!$0.replyDone || $0.queued > 0) }
        awaitingReply = utterance != .none || unfinished
        if !unfinished, !isPlaying { player.shutdown() }
    }

    // MARK: The clock

    private func startTicking() {
        guard ticksItself, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                self.tick(now: self.clock())
                if !self.needsTicking { self.ticker = nil; return }
            }
        }
    }

    private var needsTicking: Bool { isHolding || socket != nil || notice != nil }

    /// Everything time-based: silence after letting go, the missed-release guard, the recording rule,
    /// the two-minute hang-up, and notices running out.
    func tick(now: Date) {
        if let notice, now >= notice.until { self.notice = nil }

        if (isHolding || socket != nil), isRecording() {
            if isHolding { mic.stop(); isHolding = false; trigger = nil }
            hangUp()
            say(Self.recordingNotice.text, short: Self.recordingNotice.short, now: now)
            return
        }

        if isHolding {
            if let heldSince, now.timeIntervalSince(heldSince) > Self.longestHold {
                release()
            } else if trigger == .hotKey {
                if modifiersDown() {
                    modifiersUpSince = nil
                } else if let since = modifiersUpSince {
                    if now.timeIntervalSince(since) >= Self.modifierGrace { release() }
                } else {
                    modifiersUpSince = now
                }
            }
        }

        // Silence after letting go keeps the server's clock running, so it can tell the turn is over.
        if !isHolding, socket != nil, let from = silenceUntil {
            let behind = now.timeIntervalSince(from)
            if behind > 1 {
                silenceUntil = now     // the Mac slept or the app stalled: do not flood
            } else if behind + 1e-6 >= JarvisVoiceWire.frameSeconds {
                let frames = Int((behind + 1e-6) / JarvisVoiceWire.frameSeconds)
                send(.data(JarvisVoiceWire.silence(frames: frames)))
                silenceUntil = from.addingTimeInterval(Double(frames) * JarvisVoiceWire.frameSeconds)
            }
        }

        if case .released(let at) = utterance, now.timeIntervalSince(at) > Self.turnEndGrace {
            utterance = .none    // nothing was left to end: the server had ended the turn while it was held
            settle()
        }
        if awaitingReply, !isPlaying, now.timeIntervalSince(lastFromServer) > Self.replyPatience {
            utterance = .none
            turns = turns.filter { $0.value.dropped }
            settle()
        }

        if socket != nil, !isHolding, !isPlaying, now.timeIntervalSince(lastActivity) > Self.idleTimeout {
            hangUp()
        }
    }

    private func say(_ text: String, short: String, now: Date) {
        notice = Notice(text: text, short: short, until: now.addingTimeInterval(Self.noticeSeconds))
        startTicking()
    }
}
