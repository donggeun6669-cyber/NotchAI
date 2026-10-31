import AVFoundation
import Foundation
import Observation

/// Lecture recording in the situations the user actually chooses: in a classroom, an online
/// lecture through the Mac speakers or AirPods, or an online lecture recorded without playing aloud.
///
/// Built after a 69-minute lecture was lost to a recorder that reported success the whole way
/// through and saved pure silence (2026-09-22). So this one does not trust its own clock:
/// - it checks the input three seconds in, while there is still time to fix it,
/// - it says so on screen the moment the level dies mid-recording,
/// - it measures the finished file's loudness before calling it saved,
/// - and it writes in fragments, so a crash costs ten seconds rather than the whole lecture.
@MainActor
@Observable
final class RecorderService: NSObject {
    /// A user-facing situation, not an audio-engine term.
    enum Mode: String, CaseIterable, Identifiable, Codable {
        case classroom
        case onlineSpeakers
        case onlineAirPods
        case onlineMuted

        var id: String { rawValue }

        var label: String {
            switch self {
            case .classroom: "강의실"
            case .onlineSpeakers: "온라인 · 스피커"
            case .onlineAirPods: "온라인 · 에어팟"
            case .onlineMuted: "온라인 · 무음"
            }
        }

        var symbol: String {
            switch self {
            case .classroom: "person.wave.2.fill"
            case .onlineSpeakers: "macbook.and.iphone"
            case .onlineAirPods: "airpodspro"
            case .onlineMuted: "speaker.slash.fill"
            }
        }

        var explanation: String {
            switch self {
            case .classroom: "맥북 마이크로 교실 소리를 담습니다"
            case .onlineSpeakers: "맥 소리를 녹음하며 내장 스피커로 듣습니다"
            case .onlineAirPods: "맥 소리를 녹음하며 AirPods로 듣습니다"
            case .onlineMuted: "소리를 내지 않고 맥 소리만 녹음합니다"
            }
        }

        var usesMicrophone: Bool { self == .classroom }
        var usesLoopback: Bool { self != .classroom }
        /// Whether the user hears the lecture while it records. The muted preset sends the Mac's
        /// sound to the loopback driver alone, so nothing plays in the room.
        var playsAloud: Bool { self == .onlineSpeakers || self == .onlineAirPods }
    }

    /// How "맥 소리" reaches the file. NotchAI keeps the BlackHole path it was verified on;
    /// 강의녹음 uses the built-in tap so a friend installs nothing (2026-10-18).
    enum MacSound {
        /// Route the output through the BlackHole driver and record its input.
        case loopbackDriver
        /// Read a Core Audio process tap (macOS 14.2+). Nothing to install.
        case systemTap
    }

    enum Phase: Equatable {
        case idle
        case checkingInput
        case recording
        case finishing
    }

    struct Take: Equatable, Identifiable, Sendable {
        var id: URL { url }
        var url: URL
        var startedAt: Date
        var seconds: Int
        /// Filled in once the file has been measured; nil while that is still running.
        var check: RecordingCheck?
    }

    enum Trouble: Equatable {
        case denied
        case noLoopback
        case noMicrophone
        case noSpeakers
        case noAirPods
        case routingFailed
        case deadInput
        /// The tap delivered silence. Also what a refused system-audio permission looks like.
        case deadSystemAudio
        case captureBehind(Int)
        case failed(String)

        private static var appName: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "NotchAI"
        }

        var message: String {
            switch self {
            case .denied:
                "마이크 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 \(Self.appName)을(를) 켜 주세요."
            case .deadSystemAudio:
                "입력 확인 실패 · 맥 소리가 들어오지 않았습니다. 강의가 재생 중인지 확인하고, 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 \(Self.appName)을(를) 켜 주세요."
            case .noLoopback:
                "온라인 강의를 녹음하려면 BlackHole이 필요합니다. 설치 후 재부팅해 주세요."
            case .noMicrophone:
                "쓸 수 있는 마이크가 없습니다."
            case .noSpeakers:
                "내장 스피커를 찾지 못했습니다. 오디오 장치를 다시 연결해 주세요."
            case .noAirPods:
                "AirPods가 연결되어 있지 않습니다. 먼저 연결한 뒤 다시 확인해 주세요."
            case .routingFailed:
                "맥 소리를 녹음 쪽으로 돌리지 못했습니다. 소리가 안 담길 수 있어 시작하지 않았습니다."
            case .deadInput:
                "입력 확인 실패 · 소리가 들어오지 않아 녹음을 시작하지 않았습니다."
            case .captureBehind(let seconds):
                "🔴 저장이 \(seconds)초 밀렸습니다. 녹음을 멈추고 새 파일로 이어 주세요."
            case .failed(let why):
                "녹음을 시작하지 못했습니다: \(why)"
            }
        }
    }

    nonisolated static let folder = AppPaths.recordings
    /// Takes shorter than this are treated as input checks and kept under an honest recovery name.
    nonisolated static let minimumSeconds = 3
    nonisolated static let recentCount = 5
    /// How long after starting the input is judged. Long enough for a device to settle, short
    /// enough that a whole lecture is not lost to a wrong setting.
    nonisolated static let startupCheckSeconds = 3.0
    /// Continuous silence this long mid-recording raises the alarm.
    nonisolated static let silenceAlarmSeconds = 30.0
    /// A level below this reads as nothing arriving.
    nonisolated static let deadLevel = 0.02

    private static let modeKey = "recorderMode"
    private static let micKey = "recorderMicUID"
    /// Where the sound goes back to if the app dies while the muted preset holds the output.
    private static let restoreOutputKey = "recorderRestoreOutputUID"

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var elapsed: TimeInterval = 0
    /// 0…1 from the input, so silence is visible while it happens.
    private(set) var level: Double = 0
    /// Highest level seen during the three-second input check. Judging one instant caused false
    /// failures whenever the check landed between words or between two short system sounds.
    private var startupPeakLevel: Double = 0
    /// True once the input has been quiet for `silenceAlarmSeconds`, or failed its start check.
    private(set) var silenceAlarm = false
    private(set) var recents: [Take] = []
    private(set) var trouble: Trouble?
    /// The verdict on the take that just finished; cleared when a new one starts.
    private(set) var lastCheck: RecordingCheck?
    private(set) var microphones: [AudioDevices.Device] = []

    var mode: Mode = .classroom {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if !isRunning { trouble = nil }
        }
    }

    /// UID of the chosen microphone; nil means the Mac's current default input.
    var microphoneUID: String? {
        didSet {
            guard microphoneUID != oldValue else { return }
            UserDefaults.standard.set(microphoneUID, forKey: Self.micKey)
        }
    }

    var isRunning: Bool { phase == .checkingInput || phase == .recording }
    /// The last attempt went wrong (the input check heard nothing, the file failed its check,
    /// permission was refused) and nobody has dismissed it yet. Twice the first attempt of a
    /// lecture failed its 3-second check while 동근님 believed it was recording (2026-10-03,
    /// 2026-10-07), so this stays up until it is seen and dismissed, or the next start.
    var needsAttention: Bool { phase == .idle && (trouble != nil || silenceAlarm) }
    var isBusy: Bool { phase != .idle }
    var isLoopbackMissing: Bool {
        mode.usesLoopback && macSound == .loopbackDriver && AudioDevices.loopback() == nil
    }
    var isListeningDeviceMissing: Bool { mode.playsAloud && listeningDevice == nil }
    var readinessTrouble: Trouble? {
        if mode.usesMicrophone && chosenMicrophone == nil { return .noMicrophone }
        if isLoopbackMissing { return .noLoopback }
        if isListeningDeviceMissing { return mode == .onlineAirPods ? .noAirPods : .noSpeakers }
        return nil
    }
    var canStart: Bool { !isBusy && readinessTrouble == nil }

    private let session = AVCaptureSession()
    /// A *movie* output, not an audio one: only this writes in fragments (every 10s by default),
    /// so a crash leaves a playable file instead of nothing.
    private let output = AVCaptureMovieFileOutput()
    /// Set while playback is routed through the loopback driver; restored on stop.
    private var multiOutput: AudioDevices.Device?
    private var previousOutput: AudioDevices.Device?
    /// Muted preset only: undoes a mute-key press on the loopback the instant it happens.
    private var audibilityWatch: AudioDevices.AudibilityWatch?
    /// Recoverable QuickTime fragments are written here while recording.
    private var pendingURL: URL?
    /// The user-facing m4a destination, created only after the capture has closed.
    private var pendingFinalURL: URL?
    private var pendingTake: Take?
    private var keepPendingFile = true
    private var troubleAfterFinish: Trouble?
    private var silentSince: Date?
    private let folderURL: URL
    let macSound: MacSound
    /// The running tap recording, for online presets under `.systemTap`. AVCapture is not used then.
    private var systemCapture: SystemAudioCapture?

    /// Tests pass their own folder so they never touch the real recordings.
    init(folder: URL = RecorderService.folder, macSound: MacSound = .loopbackDriver) {
        folderURL = folder
        self.macSound = macSound
        super.init()
        if let saved = UserDefaults.standard.string(forKey: Self.modeKey) {
            // Migrate the first recorder UI, which exposed engine terms instead of situations.
            mode = Mode(rawValue: saved) ?? (saved == "mic" ? .classroom : .onlineSpeakers)
        }
        microphoneUID = UserDefaults.standard.string(forKey: Self.micKey)
        // A crash could have left devices behind, and the Mac listening through one of them.
        AudioDevices.removeStaleAggregates()
        restoreOutputAfterCrash()
        reloadDevices()
        // Off the main thread at launch: reading the recordings folder once kept the notch from
        // appearing for half a minute after an update (2026-11-01, the app waited inside `open`).
        let folder = folderURL
        Task.detached(priority: .utility) { [weak self] in
            let takes = RecorderService.recentTakes(in: folder)
            await MainActor.run {
                guard let self, self.recents.isEmpty else { return }
                self.recents = takes
            }
        }
    }

    // MARK: - Devices

    func reloadDevices() {
        microphones = AudioDevices.inputs().filter {
            !$0.name.localizedCaseInsensitiveContains(AudioDevices.loopbackNeedle)
                && !$0.name.hasPrefix(AudioDevices.aggregatePrefix)
        }
        if let uid = microphoneUID, !microphones.contains(where: { $0.uid == uid }) {
            microphoneUID = nil
        }
    }

    var chosenMicrophone: AudioDevices.Device? {
        if let uid = microphoneUID, let match = microphones.first(where: { $0.uid == uid }) {
            return match
        }
        return AudioDevices.defaultInput() ?? microphones.first
    }

    var sourceSummary: String {
        switch mode {
        case .classroom:
            chosenMicrophone?.name ?? "마이크 없음"
        case .onlineSpeakers:
            "맥 소리 → \(listeningDevice?.name ?? "내장 스피커 없음")"
        case .onlineAirPods:
            "맥 소리 → \(listeningDevice?.name ?? "AirPods 없음")"
        case .onlineMuted:
            "맥 소리 → 녹음만 · 스피커 꺼짐"
        }
    }

    var listeningDevice: AudioDevices.Device? {
        switch mode {
        case .classroom, .onlineMuted: nil
        case .onlineSpeakers: AudioDevices.builtInOutput()
        case .onlineAirPods: AudioDevices.airPodsOutput()
        }
    }

    // MARK: - Start and stop

    private var usesSystemTap: Bool { macSound == .systemTap && mode.usesLoopback }

    /// "알겠어요" on a failure: it has been seen.
    func dismissTrouble() {
        guard phase == .idle else { return }
        trouble = nil
        silenceAlarm = false
    }

    func toggle() {
        if isRunning { stop() } else if !isBusy { start() }
    }

    func start() {
        guard !isBusy else { return }
        trouble = nil
        lastCheck = nil
        silenceAlarm = false
        silentSince = nil
        reloadDevices()
        // The tap asks for its own "system audio" permission when it starts; a friend recording
        // only online lectures should not also be asked for the microphone.
        if usesSystemTap {
            beginRecording()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.beginRecording() } else { self.trouble = .denied }
                }
            }
        default:
            trouble = .denied
        }
    }

    /// Requests a stop. The file is not touched until AVCapture reports that it has finished
    /// writing; a fixed sleep here used to race long recordings and could verify an unfinished file.
    @discardableResult
    func stop(now: Date = .now) -> Take? {
        guard let startedAt, pendingURL != nil, let finalURL = pendingFinalURL else { return nil }
        let seconds = Int(now.timeIntervalSince(startedAt))
        guard phase != .finishing else { return pendingTake }
        let take = Take(url: finalURL, startedAt: startedAt, seconds: seconds)
        pendingTake = take
        keepPendingFile = troubleAfterFinish == nil && seconds >= Self.minimumSeconds
        phase = .finishing
        elapsed = TimeInterval(max(0, seconds))
        if let systemCapture {
            systemCapture.stop { [weak self] error in
                Task { @MainActor in self?.finishRecording(error: error) }
            }
        } else {
            output.stopRecording()
        }
        return keepPendingFile ? take : nil
    }

    func poll() {
        guard let startedAt, isRunning else { return }
        // Backstop for the listener installed in `routeOutputToLoopbackOnly`: in the muted preset
        // the output *is* the loopback driver, so the mute key would silence the recording itself.
        // The tap hears the Mac before the output's mute, so it needs no such guard.
        if mode == .onlineMuted, macSound == .loopbackDriver, let loopback = AudioDevices.loopback() {
            AudioDevices.keepAudible(loopback)
        }
        let decibels: Float? = systemCapture?.averagePowerLevel
            ?? output.connection(with: .audio)?.audioChannels.first?.averagePowerLevel
        if let decibels {
            level = Self.level(fromDecibels: Double(decibels))
            if phase == .checkingInput { startupPeakLevel = max(startupPeakLevel, level) }
        }
        let seconds = Date.now.timeIntervalSince(startedAt)
        if Int(seconds) != Int(elapsed) { elapsed = seconds }

        // Compare wall time with what the capture output says it has actually written. This catches
        // the old "the app ran for an hour but the file lost 20%" failure while it is happening.
        let captured = systemCapture?.recordedSeconds ?? output.recordedDuration.seconds
        if captured.isFinite, captured >= 0, seconds - captured > 4 {
            let missing = Int((seconds - captured).rounded(.down))
            trouble = .captureBehind(missing)
            silenceAlarm = true
        }

        // Silence that lasts is a broken input, not a pause in the lecture.
        if level < Self.deadLevel {
            if silentSince == nil { silentSince = .now }
            if let since = silentSince, Date.now.timeIntervalSince(since) >= Self.silenceAlarmSeconds {
                silenceAlarm = true
            }
        } else {
            silentSince = nil
            if case .captureBehind? = trouble {
                // A healthy level does not repair missing file time.
            } else {
                silenceAlarm = false
            }
            // Sound came back: the start-up warning was a false alarm (the room was simply quiet
            // when recording began). Leaving it up teaches the user to ignore the real one.
            if trouble == .deadInput || trouble == .deadSystemAudio { trouble = nil }
        }
    }

    private func beginRecording() {
        if usesSystemTap {
            beginSystemTapRecording()
            return
        }
        guard routeOutputIfNeeded(), let device = resolveDevice() else {
            teardownDevices()
            return
        }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let finalURL = Self.availableURL(
                in: folderURL, filename: Self.filename(at: .now, mode: mode))
            let url = Self.captureURL(for: finalURL)

            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                trouble = .failed("입력 장치를 열 수 없습니다")
                teardownDevices()
                return
            }
            session.addInput(input)
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()

            // Without this the movie output writes uncompressed PCM — 29MB for 38 seconds, and
            // about 3GB for a two-hour lecture. AAC mono is what the transcriber wants anyway.
            if let connection = output.connection(with: .audio) {
                output.setOutputSettings(Self.audioSettings(), for: connection)
            }
            // Make the crash-recovery promise explicit instead of relying on the framework default.
            output.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)

            pendingURL = url
            pendingFinalURL = finalURL
            startedAt = .now
            phase = .checkingInput
            elapsed = 0
            level = 0
            startupPeakLevel = 0
            keepPendingFile = true
            troubleAfterFinish = nil
            session.startRunning()
            output.startRecording(to: url, recordingDelegate: self)
            scheduleStartupCheck()
        } catch {
            trouble = .failed(error.localizedDescription)
            teardownDevices()
        }
    }

    /// The online presets without BlackHole. Speakers and AirPods become the Mac's output for the
    /// recording, as the multi-output device did before; the muted preset leaves the output alone
    /// and lets the tap hold every app's sound back from it.
    private func beginSystemTapRecording() {
        if mode.playsAloud {
            guard let listen = listeningDevice else {
                trouble = mode == .onlineAirPods ? .noAirPods : .noSpeakers
                return
            }
            if let current = AudioDevices.defaultOutput(), current.uid != listen.uid {
                guard AudioDevices.setDefaultOutput(listen) else {
                    trouble = .routingFailed
                    return
                }
                previousOutput = current
            }
        }
        guard let clock = AudioDevices.defaultOutput() ?? AudioDevices.builtInOutput() else {
            trouble = .routingFailed
            teardownDevices()
            return
        }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let finalURL = Self.availableURL(
                in: folderURL, filename: Self.filename(at: .now, mode: mode))
            let url = Self.captureURL(for: finalURL)
            let capture = SystemAudioCapture(muted: mode == .onlineMuted, clockUID: clock.uid, url: url)
            try capture.start()
            systemCapture = capture

            pendingURL = url
            pendingFinalURL = finalURL
            startedAt = .now
            phase = .checkingInput
            elapsed = 0
            level = 0
            startupPeakLevel = 0
            keepPendingFile = true
            troubleAfterFinish = nil
            scheduleStartupCheck()
        } catch {
            trouble = .failed(error.localizedDescription)
            teardownDevices()
        }
    }

    /// Keeps the first three seconds as an explicit input check. A dead source is stopped and the
    /// test file is discarded automatically, so the UI never claims a silent lecture is recording.
    private func scheduleStartupCheck() {
        Task { @MainActor in
            let checks = Int(Self.startupCheckSeconds * 10)
            for _ in 0..<checks {
                try? await Task.sleep(for: .milliseconds(100))
                guard phase == .checkingInput else { return }
                poll()
            }
            if startupPeakLevel < Self.deadLevel {
                silenceAlarm = true
                troubleAfterFinish = usesSystemTap ? .deadSystemAudio : .deadInput
                keepPendingFile = false
                _ = stop()
            } else {
                phase = .recording
            }
        }
    }

    /// "맥 소리" only works when the Mac is *playing into* the loopback driver. Point the output
    /// at a multi-output device that feeds both the speakers and BlackHole, and remember what to
    /// put back. Without this the recording is silence, which is how a lecture was lost.
    private func routeOutputIfNeeded() -> Bool {
        guard mode.usesLoopback else { return true }
        guard let loopback = AudioDevices.loopback() else {
            trouble = .noLoopback
            return false
        }
        if mode == .onlineMuted { return routeOutputToLoopbackOnly(loopback) }
        guard let listen = listeningDevice else {
            trouble = mode == .onlineAirPods ? .noAirPods : .noSpeakers
            return false
        }
        guard let current = AudioDevices.defaultOutput() else {
            trouble = .routingFailed
            return false
        }
        guard let multi = AudioDevices.makeMultiOutput(
            name: "\(AudioDevices.aggregatePrefix) 출력 \(Int(Date.now.timeIntervalSince1970))",
            listen: listen, loopback: loopback),
            AudioDevices.setDefaultOutput(multi) else {
            trouble = .routingFailed
            return false
        }
        previousOutput = current
        multiOutput = multi
        return true
    }

    /// The muted preset: the Mac plays into BlackHole and nothing else, so the room stays silent
    /// and the file still gets every sample. The previous output is also written to disk, because
    /// a crash here would otherwise leave the Mac with no audible sound at all.
    private func routeOutputToLoopbackOnly(_ loopback: AudioDevices.Device) -> Bool {
        guard let current = AudioDevices.defaultOutput() else {
            trouble = .routingFailed
            return false
        }
        AudioDevices.keepAudible(loopback)
        guard AudioDevices.setDefaultOutput(loopback) else {
            trouble = .routingFailed
            return false
        }
        if current.uid != loopback.uid {
            previousOutput = current
            UserDefaults.standard.set(current.uid, forKey: Self.restoreOutputKey)
        }
        audibilityWatch = AudioDevices.watchAudibility(of: loopback) {
            AudioDevices.keepAudible(loopback)
        }
        return true
    }

    /// Puts the sound back on the speakers when the last run died mid-recording in the muted preset.
    private func restoreOutputAfterCrash() {
        guard let uid = UserDefaults.standard.string(forKey: Self.restoreOutputKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.restoreOutputKey)
        guard let current = AudioDevices.defaultOutput(),
              current.name.localizedCaseInsensitiveContains(AudioDevices.loopbackNeedle) else { return }
        if let previous = AudioDevices.outputs().first(where: { $0.uid == uid })
            ?? AudioDevices.builtInOutput() {
            AudioDevices.setDefaultOutput(previous)
        }
    }

    /// Picks (or builds) the capture device this mode needs.
    private func resolveDevice() -> AVCaptureDevice? {
        switch mode {
        case .classroom:
            guard let mic = chosenMicrophone, let device = AVCaptureDevice(uniqueID: mic.uid) else {
                trouble = .noMicrophone
                return nil
            }
            return device
        case .onlineSpeakers, .onlineAirPods, .onlineMuted:
            guard let loopback = AudioDevices.loopback(),
                  let device = AVCaptureDevice(uniqueID: loopback.uid) else {
                trouble = .noLoopback
                return nil
            }
            return device
        }
    }

    /// Puts the Mac's sound back and drops every device this recording made. Called on stop and
    /// on any failed start, so nothing of ours is ever left holding the output.
    private func teardownDevices() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()

        if let watch = audibilityWatch {
            AudioDevices.stopWatching(watch)
            audibilityWatch = nil
        }
        if let previous = previousOutput {
            AudioDevices.setDefaultOutput(previous)
            previousOutput = nil
            UserDefaults.standard.removeObject(forKey: Self.restoreOutputKey)
        }
        if let multi = multiOutput {
            AudioDevices.destroyAggregate(multi)
            multiOutput = nil
        }
    }

    /// Called only after AVCapture has closed the file. This ordering is the integrity boundary:
    /// routing and the capture session stay alive until the writer says it is finished.
    private func finishRecording(error: Error?) {
        let recordedSuccessfully: Bool = {
            guard let error = error as NSError? else { return true }
            return error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        }()
        let take = pendingTake
        let captureURL = pendingURL
        let finalURL = pendingFinalURL
        let keepAsFinished = keepPendingFile && recordedSuccessfully
        let deferredTrouble = troubleAfterFinish

        session.stopRunning()
        systemCapture = nil
        teardownDevices()
        startedAt = nil
        pendingURL = nil
        pendingFinalURL = nil
        pendingTake = nil
        elapsed = 0
        level = 0
        silentSince = nil
        silenceAlarm = false
        phase = .idle
        troubleAfterFinish = nil

        guard let take, let captureURL, let finalURL else {
            trouble = deferredTrouble ?? error.map { .failed($0.localizedDescription) }
            return
        }
        guard keepAsFinished else {
            // Never delete captured audio automatically. A failed three-second input check or an
            // interrupted writer is moved aside with an honest name in case it contains anything.
            let recovery = Self.recoveryURL(for: captureURL)
            try? FileManager.default.moveItem(at: captureURL, to: recovery)
            trouble = deferredTrouble ?? error.map { .failed($0.localizedDescription) }
            reloadRecents()
            return
        }

        trouble = nil
        Task {
            let originalCheck = await Task.detached {
                RecordingCheck.measure(url: captureURL, expectedSeconds: take.seconds)
            }.value
            guard !originalCheck.problems.contains(.unreadable),
                  await Self.exportM4A(from: captureURL, to: finalURL) else {
                let recovery = Self.recoveryURL(for: captureURL)
                try? FileManager.default.moveItem(at: captureURL, to: recovery)
                self.lastCheck = originalCheck.problems.contains(.unreadable)
                    ? originalCheck
                    : RecordingCheck(expectedSeconds: take.seconds, fileSeconds: 0,
                                     meanDecibels: -160, peakDecibels: -160,
                                     problems: [.unreadable])
                self.silenceAlarm = true
                self.reloadRecents()
                return
            }
            let finalCheck = await Task.detached {
                RecordingCheck.measure(url: finalURL, expectedSeconds: take.seconds)
            }.value
            if !finalCheck.problems.contains(.unreadable),
               finalCheck.fileSeconds >= originalCheck.fileSeconds - 1 {
                // The m4a is independently readable and complete; the working movie is now only a
                // generated intermediate. Until this point it was never touched.
                try? FileManager.default.removeItem(at: captureURL)
            } else {
                let recovery = Self.recoveryURL(for: captureURL)
                try? FileManager.default.moveItem(at: captureURL, to: recovery)
            }
            self.lastCheck = finalCheck
            self.silenceAlarm = !finalCheck.isClean
            self.reloadRecents()
        }
    }

    /// Turns the fragment-safe QuickTime capture into the m4a used by the transcript pipeline.
    /// The caller keeps the movie until the exported file has passed its own duration/audio check.
    nonisolated static func exportM4A(from captureURL: URL, to finalURL: URL) async -> Bool {
        let asset = AVURLAsset(url: captureURL)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        do {
            try await export.export(to: finalURL, as: .m4a)
            return FileManager.default.fileExists(atPath: finalURL.path)
        } catch {
            return false
        }
    }

    // MARK: - Files

    func reloadRecents() {
        recents = Self.recentTakes(in: folderURL)
    }

    nonisolated static func recentTakes(in folder: URL) -> [Take] {
        let keys: Set<URLResourceKey> = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        // Newest first, and only as many files opened as it takes: the notch reloads this every
        // time it opens, and the folder holds a whole semester.
        let dated = urls
            .filter { $0.pathExtension == "m4a" }
            .map { ($0, (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var takes: [Take] = []
        for (url, created) in dated where takes.count < recentCount {
            let seconds = Int(duration(of: url))
            if seconds > 0 { takes.append(Take(url: url, startedAt: created, seconds: seconds)) }
        }
        return takes
    }

    /// Length of a finished file, or 0 when it cannot be read.
    nonisolated static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    nonisolated static func recoveryURL(for url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_진행중", with: "")
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        return availableURL(in: url.deletingLastPathComponent(),
                            filename: "\(stem)_확인필요.\(ext)")
    }

    nonisolated static func captureURL(for finalURL: URL) -> URL {
        let stem = finalURL.deletingPathExtension().lastPathComponent
        return availableURL(in: finalURL.deletingLastPathComponent(),
                            filename: "\(stem)_진행중.mov")
    }

    /// Never hand the writer an existing path. Two checks in the same minute get numbered instead
    /// of replacing one another.
    nonisolated static func availableURL(in folder: URL, filename: String) -> URL {
        let base = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for index in 2...999 {
            let candidate = folder.appendingPathComponent("\(stem)_\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(stem)_\(UUID().uuidString).\(ext)")
    }

    // MARK: - Pure helpers (tested)

    /// AAC mono at 64 kbps: about 30MB an hour, and the shape whisper.cpp reads best. A
    /// function rather than a stored constant because `[String: Any]` cannot be shared under
    /// Swift 6 concurrency rules.
    nonisolated static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
    }

    /// The date part follows the DEAN recording convention; the suffix makes the situation clear.
    nonisolated static func filename(at date: Date, mode: Mode = .classroom,
                                     calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let suffix = switch mode {
        case .classroom: "_강의실"
        case .onlineSpeakers: "_온라인_스피커"
        case .onlineAirPods: "_온라인_에어팟"
        case .onlineMuted: "_온라인_무음"
        }
        return "\(f.string(from: date))_녹음\(suffix).m4a"
    }

    /// Meter decibels to a bar height. -50 dB and below reads as silence, which is where a dead
    /// input sits. Values far outside the normal range (a disconnected channel reports about
    /// -758) also land on zero.
    nonisolated static func level(fromDecibels decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        let floor = -50.0
        guard decibels > floor else { return 0 }
        return min(1, (decibels - floor) / -floor)
    }

    /// Running clock: "12:34" or "1:02:03".
    nonisolated static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s < 3600
            ? String(format: "%d:%02d", s / 60, s % 60)
            : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1시간 05분" / "23분" / "42초".
    nonisolated static func duration(_ seconds: Int) -> String {
        RecordingCheck.duration(seconds)
    }
}

extension RecorderService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.finishRecording(error: error)
        }
    }
}
