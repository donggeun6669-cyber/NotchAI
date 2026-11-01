import Foundation

// The voice service's WebSocket (`jarvis_voice/server.py` on the desktop, 2026-11-01): the notch
// sends `start`, then 16 kHz mono int16 audio; the server answers with JSON events and Jarvis's
// voice as binary chunks. Pure functions only, so every byte the notch sends or reads is testable.

/// One JSON event from the voice server. Unknown types are kept as `.other`, never guessed.
enum JarvisVoiceEvent: Equatable {
    case ready(conversation: String, sampleRateOut: Int, title: String?)
    /// listening · thinking · speaking · idle, and whether the server hears the user right now.
    case state(String, userSpeaking: Bool)
    case endOfTurn(turn: Int)
    /// What the server understood. Empty when it was only noise.
    case heard(turn: Int, text: String)
    /// A tool the brain is using for this turn.
    case status(turn: Int, text: String)
    case replyDelta(turn: Int, text: String)
    case replyDone(turn: Int, text: String?)
    /// Stop playing that turn now. "barge_in" (the user talked over it) or "continued" (the user had
    /// not finished; the next `heard` holds both parts).
    case interrupt(turn: Int, reason: String?)
    /// A blip too short to be speech.
    case ignored(String?)
    case error(String, turn: Int?)
    case other(String)

    static func parse(_ text: String) -> JarvisVoiceEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let turn = (object["turn"] as? NSNumber)?.intValue
        switch type {
        case "ready":
            guard let id = object["conv_id"] as? String, !id.isEmpty else { return nil }
            let rate = (object["sample_rate_out"] as? NSNumber)?.intValue ?? 0
            return .ready(conversation: id, sampleRateOut: rate > 0 ? rate : JarvisVoiceWire.defaultRateOut,
                          title: object["title"] as? String)
        case "state":
            guard let state = object["state"] as? String else { return nil }
            return .state(state, userSpeaking: object["user_speaking"] as? Bool ?? false)
        case "end_of_turn":
            return turn.map { .endOfTurn(turn: $0) }
        case "heard":
            return turn.map { .heard(turn: $0, text: object["text"] as? String ?? "") }
        case "status":
            return turn.map { .status(turn: $0, text: object["text"] as? String ?? "") }
        case "reply_delta":
            return turn.map { .replyDelta(turn: $0, text: object["text"] as? String ?? "") }
        case "reply_done":
            return turn.map { .replyDone(turn: $0, text: object["text"] as? String) }
        case "interrupt":
            return turn.map { .interrupt(turn: $0, reason: object["reason"] as? String) }
        case "ignored":
            return .ignored(object["reason"] as? String)
        case "error":
            return .error(object["message"] as? String ?? "오류", turn: turn)
        default:
            return .other(type)
        }
    }
}

/// One piece of Jarvis's voice: 8-byte header (uint32 turn, uint32 seq, little-endian), then int16
/// mono PCM at `ready.sample_rate_out`.
struct JarvisVoiceChunk: Equatable {
    var turn: Int
    var seq: Int
    var samples: [Int16]

    static func parse(_ data: Data) -> JarvisVoiceChunk? {
        guard data.count >= 8, (data.count - 8) % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        var samples = [Int16](repeating: 0, count: (bytes.count - 8) / 2)
        for index in samples.indices {
            let low = UInt16(bytes[8 + index * 2]), high = UInt16(bytes[9 + index * 2])
            samples[index] = Int16(bitPattern: low | high << 8)
        }
        return JarvisVoiceChunk(turn: u32(0), seq: u32(4), samples: samples)
    }
}

/// What the notch sends.
enum JarvisVoiceWire {
    /// The microphone audio the server expects.
    static let sampleRate = 16_000
    /// 20 ms, what the browser client sends.
    static let frameSamples = 320
    static let frameSeconds = Double(frameSamples) / Double(sampleRate)
    /// Used only if `ready` leaves the output rate out.
    static let defaultRateOut = 44_100

    /// `https://desk…ts.net` → `wss://desk…ts.net/voice/ws` (same address as everything else).
    static func url(base: URL) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        default: return nil
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path + "/voice/ws"
        parts.query = nil
        return parts.url
    }

    static func start(conversation: String?) -> String {
        var object: [String: Any] = ["type": "start"]
        if let conversation { object["conv_id"] = conversation }
        return json(object)
    }

    static func playback(turn: Int, started: Bool) -> String {
        json(["type": "playback", "turn": turn, "state": started ? "started" : "ended"])
    }

    static let hangup = #"{"type":"hangup"}"#

    /// Little-endian int16, as the server reads it.
    static func pcm(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8))
        }
        return data
    }

    /// Generated silence (not from the microphone), `frames` × 20 ms.
    static func silence(frames: Int) -> Data {
        Data(count: max(0, frames) * frameSamples * 2)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
