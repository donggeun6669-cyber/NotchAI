import AVFoundation
import Foundation

/// What a finished recording actually contains, measured from the file rather than from the
/// clock that produced it.
///
/// This exists because on 2026-09-22 a 69-minute lecture recording reported "보존율 99.9%" and
/// held nothing: the script compared elapsed time against file length and never looked at the
/// audio. Length is not evidence. Loudness is.
struct RecordingCheck: Equatable, Sendable {
    /// Seconds the recorder was running.
    var expectedSeconds: Int
    /// Seconds actually in the file.
    var fileSeconds: Int
    /// Mean level across the file, in dBFS. -160 is digital silence.
    var meanDecibels: Double
    /// Loudest single sample, in dBFS.
    var peakDecibels: Double
    var problems: [Problem]

    enum Problem: Equatable, Sendable {
        /// Nothing audible anywhere in the file.
        case silent
        /// Audio present but far below speech level throughout.
        case tooQuiet
        /// The file is shorter than the time spent recording.
        case truncated(missingSeconds: Int)
        /// The file could not be read at all.
        case unreadable

        var message: String {
            switch self {
            case .silent:
                "🔴 소리가 하나도 안 담겼습니다. 입력을 잘못 골랐을 가능성이 큽니다"
            case .tooQuiet:
                "🟠 소리가 너무 작습니다. 들을 수는 있어도 전사 품질이 떨어집니다"
            case .truncated(let missing):
                "🔴 \(missing)초가 비었습니다. 녹음한 시간보다 파일이 짧습니다"
            case .unreadable:
                "🔴 파일을 읽을 수 없습니다"
            }
        }
    }

    var isClean: Bool { problems.isEmpty }

    /// One line for the panel: what was kept, and whether it is usable.
    var summary: String {
        let length = RecordingCheck.duration(fileSeconds)
        guard let first = problems.first else {
            return "✅ \(length) 저장 · 소리 정상 (평균 \(Int(meanDecibels))dB)"
        }
        return first.message
    }

    // MARK: - Thresholds

    /// Below this the file is silence. A truly empty AAC file measures about -91 dB, which is
    /// exactly what the lost lecture measured.
    static let silenceCeiling: Double = -80
    /// Below this there is signal, but not enough for a transcript to be reliable.
    static let quietCeiling: Double = -45
    /// A file may fall this far short of the clock before it counts as truncated; encoders
    /// legitimately drop a fraction of a second at the end.
    static let allowedGapSeconds = 2

    // MARK: - Measuring

    /// Reads the file and judges it. Sampled rather than read whole, so an hour-long take is
    /// checked in a moment.
    static func measure(url: URL, expectedSeconds: Int, samples: Int = 120) -> RecordingCheck {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0,
              file.length > 0 else {
            return RecordingCheck(expectedSeconds: expectedSeconds, fileSeconds: 0,
                                  meanDecibels: -160, peakDecibels: -160, problems: [.unreadable])
        }
        let rate = file.fileFormat.sampleRate
        let fileSeconds = Int(Double(file.length) / rate)
        let (mean, peak) = levels(of: file, samples: samples)

        var problems: [Problem] = []
        if mean <= silenceCeiling && peak <= silenceCeiling {
            problems.append(.silent)
        } else if mean <= quietCeiling {
            problems.append(.tooQuiet)
        }
        let gap = expectedSeconds - fileSeconds
        if gap > allowedGapSeconds {
            problems.append(.truncated(missingSeconds: gap))
        }
        return RecordingCheck(expectedSeconds: expectedSeconds, fileSeconds: fileSeconds,
                              meanDecibels: mean, peakDecibels: peak, problems: problems)
    }

    /// Mean and peak dBFS, from evenly spaced windows across the whole file. Sampling the middle
    /// only would miss a recording that died after five minutes.
    private static func levels(of file: AVAudioFile, samples: Int) -> (mean: Double, peak: Double) {
        let format = file.processingFormat
        let windowFrames = AVAudioFrameCount(min(Double(file.length), format.sampleRate * 0.2))
        guard windowFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return (-160, -160)
        }
        let windows = max(1, min(samples, Int(file.length / AVAudioFramePosition(windowFrames))))
        var sumOfSquares = 0.0
        var counted = 0
        var peak = 0.0

        for index in 0..<windows {
            let position = AVAudioFramePosition(Double(index) / Double(windows) * Double(file.length))
            file.framePosition = min(position, max(0, file.length - AVAudioFramePosition(windowFrames)))
            guard (try? file.read(into: buffer, frameCount: windowFrames)) != nil,
                  buffer.frameLength > 0, let channels = buffer.floatChannelData else { continue }
            for channel in 0..<Int(format.channelCount) {
                let data = channels[channel]
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(data[frame])
                    sumOfSquares += value * value
                    peak = max(peak, abs(value))
                    counted += 1
                }
            }
        }
        guard counted > 0 else { return (-160, -160) }
        return (decibels(from: (sumOfSquares / Double(counted)).squareRoot()), decibels(from: peak))
    }

    /// Linear amplitude (0…1) to dBFS, floored at -160 so silence has a finite number.
    static func decibels(from amplitude: Double) -> Double {
        guard amplitude > 0.0000000001 else { return -160 }
        return max(-160, 20 * log10(amplitude))
    }

    /// "1시간 05분" / "23분" / "42초".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)초" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)분" }
        return String(format: "%d시간 %02d분", minutes / 60, minutes % 60)
    }
}
