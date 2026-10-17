import AVFoundation
import CoreAudio
import Foundation

/// Records what the Mac is playing with a Core Audio process tap (macOS 14.2+), so 강의녹음 needs
/// no BlackHole, no Terminal and no reboot on a friend's Mac (2026-10-18).
///
/// AVCapture cannot see a tap — an aggregate that carries one reports no input channels to it — so
/// this reads the tap through an IOProc and writes the same fragment-safe QuickTime movie that
/// `AVCaptureMovieFileOutput` writes for the microphone. A crash still costs ten seconds, not the
/// lecture. Measured on this Mac before building it: the tap hears every app *before* the output
/// device's mute and volume, so the mute key cannot silence a recording, and a `.muted` tap keeps
/// the room silent while the file still gets the sound.
///
/// A tap delivers nothing at all while no app is playing (measured: zero IO callbacks in five
/// silent seconds). So the gaps are filled with silence here: the file keeps the lecture's real
/// timeline, a paused lecture reads as silence (the 30-second alarm) and not as lost file time.
final class SystemAudioCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case tap(OSStatus)
        case aggregate(OSStatus)
        case device(OSStatus)
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .tap(let status): "맥 소리를 연결하지 못했습니다 (탭 \(status))"
            case .aggregate(let status): "녹음 장치를 만들지 못했습니다 (\(status))"
            case .device(let status): "녹음 장치를 시작하지 못했습니다 (\(status))"
            case .writer(let why): "파일을 쓰지 못했습니다: \(why)"
            }
        }
    }

    /// Prefix shared with every other aggregate the recorder makes, so a crash leftover is found.
    static let aggregateName = "\(AudioDevices.aggregatePrefix) 맥 소리"

    private let muted: Bool
    private let clockUID: String
    private let url: URL

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMAudioFormatDescription?
    private var sampleRate: Double = 48_000

    /// The IOProc runs here; appends go to `writeQueue` so a slow disk never stalls the tap.
    private let ioQueue = DispatchQueue(label: "SystemAudioCapture.io", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "SystemAudioCapture.write")

    private let lock = NSLock()
    private var framesWritten: Int64 = 0
    /// Where the next block lands in the file. Touched on `writeQueue` only.
    private var nextFrame: Int64 = 0
    private var startUptime: TimeInterval = 0
    private var filler: DispatchSourceTimer?
    /// Silence is written once the tap has been quiet this long; real sound arrives every ~10ms.
    private static let fillAfter = 0.5
    /// Left unfilled behind "now", so sound arriving just after a fill is not pushed late.
    private static let fillSlack = 0.1
    private var latestDecibels: Float = -160
    private var writeError: String?

    /// - Parameters:
    ///   - muted: keep the sound out of the speakers while recording (the 「무음」 preset).
    ///   - clockUID: the output device that drives the recording clock — where the user listens.
    init(muted: Bool, clockUID: String, url: URL) {
        self.muted = muted
        self.clockUID = clockUID
        self.url = url
    }

    // MARK: - Reading, from any thread

    /// Loudness of the last buffer in dB, the scale `AVCaptureAudioChannel.averagePowerLevel` uses.
    var averagePowerLevel: Float { lock.withLock { latestDecibels } }

    /// Seconds actually handed to the file, silence included. Falls behind the wall clock only when
    /// the writer cannot keep up — the recorder's "저장이 밀렸습니다" alarm.
    var recordedSeconds: Double { lock.withLock { Double(framesWritten) / sampleRate } }

    // MARK: - Start and stop

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = Self.aggregateName
        description.isPrivate = true
        description.muteBehavior = muted ? .muted : .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.tap(status) }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var tapFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &tapFormat)
        guard status == noErr, tapFormat.mSampleRate > 0 else {
            stopDevices()
            throw Failure.tap(status)
        }
        sampleRate = tapFormat.mSampleRate

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: "com.dongeun.NotchAI.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stopDevices()
            throw Failure.aggregate(status)
        }

        try startWriter()

        let channels = Int(max(1, tapFormat.mChannelsPerFrame))
        let interleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.receive(inputData, channels: channels, interleaved: interleaved)
        }
        guard status == noErr else {
            stopDevices()
            throw Failure.device(status)
        }
        startUptime = ProcessInfo.processInfo.systemUptime
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stopDevices()
            throw Failure.device(status)
        }
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.fillSilence() }
        timer.resume()
        filler = timer
    }

    /// Stops the tap first, then closes the file. `completion` runs once the movie is on disk,
    /// the same moment AVCapture's "didFinishRecording" would arrive.
    func stop(completion: @escaping @Sendable (Error?) -> Void) {
        stopDevices()
        // Drain the IO queue so no buffer arrives after the input is marked finished.
        ioQueue.sync {}
        writeQueue.async { [self] in
            filler?.cancel()
            filler = nil
            guard let writer, let input else {
                completion(Failure.writer("시작되지 않았습니다"))
                return
            }
            input.markAsFinished()
            writer.finishWriting { [self] in
                guard let writer = self.writer else { return completion(nil) }
                let failure = writer.status == .completed
                    ? lock.withLock { writeError }.map { Failure.writer($0) }
                    : Failure.writer(writer.error?.localizedDescription ?? "알 수 없는 오류")
                completion(failure)
            }
        }
    }

    private func stopDevices() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Writing

    /// AAC mono at the tap's own rate, in a QuickTime movie flushed every ten seconds — the same
    /// file shape the microphone path produces, so the m4a export and checks are unchanged.
    private func startWriter() throws {
        var mono = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &mono, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else {
            stopDevices()
            throw Failure.writer("소리 형식")
        }
        format = description

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)
            var settings = RecorderService.audioSettings()
            settings[AVSampleRateKey] = sampleRate
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings,
                                           sourceFormatHint: description)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.writer("입력을 붙일 수 없습니다") }
            writer.add(input)
            guard writer.startWriting() else {
                throw Failure.writer(writer.error?.localizedDescription ?? "시작 실패")
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
        } catch {
            stopDevices()
            throw error as? Failure ?? Failure.writer(error.localizedDescription)
        }
    }

    /// IOProc body: fold the tap's channels to mono, measure, and queue the block for the file.
    private func receive(_ list: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mData != nil else { return }
        let frames = interleaved
            ? Int(first.mDataByteSize) / (4 * channels)
            : Int(first.mDataByteSize) / 4
        guard frames > 0 else { return }

        var samples = [Float](repeating: 0, count: frames)
        var sumSquares: Float = 0
        if interleaved {
            let data = first.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                samples[frame] = sum / Float(channels)
            }
        } else {
            let used = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            for frame in 0..<frames {
                var sum: Float = 0
                for data in used { sum += data[frame] }
                samples[frame] = sum / Float(max(1, used.count))
            }
        }
        for value in samples { sumSquares += value * value }
        let decibels = sumSquares > 0 ? 10 * log10(sumSquares / Float(frames)) : -160
        lock.withLock { latestDecibels = decibels }
        writeQueue.async { [self] in append(samples) }
    }

    /// Writes one block at the end of the file. On `writeQueue`.
    private func append(_ samples: [Float]) {
        guard let input, let writer, writer.status == .writing else {
            if let writer, writer.status == .failed {
                lock.withLock { writeError = writer.error?.localizedDescription }
            }
            return
        }
        // Real-time input: a block the encoder cannot take now is lost, and shows as
        // `recordedSeconds` falling behind.
        guard input.isReadyForMoreMediaData,
              let buffer = makeSampleBuffer(samples, at: nextFrame),
              input.append(buffer) else { return }
        nextFrame += Int64(samples.count)
        lock.withLock { framesWritten += Int64(samples.count) }
    }

    /// Timer on `writeQueue`: when the tap has gone quiet, write the missing time as silence.
    private func fillSilence() {
        let rate = sampleRate
        let due = Int64((ProcessInfo.processInfo.systemUptime - startUptime) * rate)
        guard due - nextFrame > Int64(Self.fillAfter * rate) else { return }
        var missing = due - nextFrame - Int64(Self.fillSlack * rate)
        lock.withLock { latestDecibels = -160 }
        while missing > 0 {
            let chunk = Int(min(missing, Int64(rate)))
            let before = nextFrame
            append([Float](repeating: 0, count: chunk))
            guard nextFrame > before else { return }   // writer busy or failed; try next tick
            missing -= Int64(chunk)
        }
    }

    private func makeSampleBuffer(_ samples: [Float], at frame: Int64) -> CMSampleBuffer? {
        guard let format else { return nil }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var buffer: CMSampleBuffer?
        let time = CMTime(value: frame, timescale: CMTimeScale(sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }
}
