import CoreAudio
import Foundation

/// Finding the exact input and listening devices used by the three lecture recording presets.
///
/// Aggregate devices made here are named with `aggregatePrefix` and torn down as soon as the
/// recording stops; `removeStaleAggregates()` clears any left behind by a crash. The DEAN
/// scripts learned this the hard way — a leftover device stole the default output later and
/// killed the volume keys (2026-09-16). This one is only ever an *input*, and the Mac's default
/// input is never changed, so it cannot repeat that failure.
enum AudioDevices {
    /// A device the user could record from.
    struct Device: Equatable, Identifiable {
        var id: AudioDeviceID
        var name: String
        var uid: String
    }

    /// The loopback driver that carries what the Mac is playing. Installed separately.
    static let loopbackNeedle = "BlackHole"
    /// Every aggregate this app makes starts with this, so leftovers can be recognised.
    static let aggregatePrefix = "NotchAI 녹음"

    // MARK: - Listing

    /// Every device with at least one input channel.
    static func inputs() -> [Device] {
        all().filter { channelCount(of: $0.id, scope: kAudioObjectPropertyScopeInput) > 0 }
    }

    /// Every device that can play sound.
    static func outputs() -> [Device] {
        all().filter { channelCount(of: $0.id, scope: kAudioObjectPropertyScopeOutput) > 0 }
    }

    /// The Mac's own speakers. This is deliberately not the current default: the default may be
    /// AirPods while the user is choosing the separate "online · speakers" preset.
    static func builtInOutput() -> Device? {
        outputs().first { transportType(of: $0.id) == kAudioDeviceTransportTypeBuiltIn }
            ?? outputs().first { $0.name.localizedCaseInsensitiveContains("speaker")
                || $0.name.localizedCaseInsensitiveContains("스피커") }
    }

    /// Connected AirPods. Bluetooth headphones with another name are not silently substituted —
    /// the preset says AirPods, so the UI should fail clearly when they are not connected.
    static func airPodsOutput() -> Device? {
        outputs().first { $0.name.localizedCaseInsensitiveContains("AirPods") }
    }

    /// The loopback input, or nil when BlackHole is not installed.
    static func loopback() -> Device? {
        inputs().first { $0.name.localizedCaseInsensitiveContains(loopbackNeedle) }
    }

    /// The Mac's current default output — where the user is actually listening.
    static func defaultOutput() -> Device? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Points the Mac's output at `device`. Used only to route playback through the loopback
    /// driver during a recording, and always undone when it stops.
    @discardableResult
    static func setDefaultOutput(_ device: Device) -> Bool {
        var id = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    /// Makes sure `device` is not muted and is at full volume. Returns true when it had to change
    /// something. Used on the loopback driver while it is the Mac's only output: its volume and
    /// mute feed straight into the recording, so the mute key would record silence.
    @discardableResult
    static func keepAudible(_ device: Device) -> Bool {
        var changed = false
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device.id, &muteAddress),
           AudioObjectGetPropertyData(device.id, &muteAddress, 0, nil, &size, &muted) == noErr,
           muted != 0 {
            var off = UInt32(0)
            changed = AudioObjectSetPropertyData(device.id, &muteAddress, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &off) == noErr
        }
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var volume = Float32(1)
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device.id, &volumeAddress),
           AudioObjectGetPropertyData(device.id, &volumeAddress, 0, nil, &size, &volume) == noErr,
           volume < 0.999 {
            var full = Float32(1)
            changed = AudioObjectSetPropertyData(device.id, &volumeAddress, 0, nil,
                                                 UInt32(MemoryLayout<Float32>.size), &full) == noErr
                || changed
        }
        return changed
    }

    /// A subscription to a device's mute and volume, made by `watchAudibility`. Keep it alive for
    /// as long as the watch should run, then pass it to `stopWatching`.
    final class AudibilityWatch: @unchecked Sendable {
        fileprivate let device: AudioDeviceID
        fileprivate let onChange: @Sendable () -> Void
        fileprivate init(device: AudioDeviceID, onChange: @escaping @Sendable () -> Void) {
            self.device = device
            self.onChange = onChange
        }
    }

    private static let audibilitySelectors = [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar]

    /// A C callback with the watch as its context, not a Swift closure: a closure passed as a
    /// listener *block* is re-bridged on every call, so removing it silently fails and the
    /// listener keeps firing after the recording (found 2026-09-29).
    private static let audibilityProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let watch = Unmanaged<AudibilityWatch>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { watch.onChange() }
        return noErr
    }

    /// Calls `onChange` on the main queue the moment `device`'s output mute or volume changes, so
    /// a press of the mute key can be undone before any audio is lost — polling once a second
    /// would drop up to a second of the lecture.
    static func watchAudibility(of device: Device, onChange: @escaping @Sendable () -> Void) -> AudibilityWatch {
        let watch = AudibilityWatch(device: device.id, onChange: onChange)
        let context = Unmanaged.passUnretained(watch).toOpaque()
        for selector in audibilitySelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(device.id, &address) {
                AudioObjectAddPropertyListener(device.id, &address, audibilityProc, context)
            }
        }
        return watch
    }

    static func stopWatching(_ watch: AudibilityWatch) {
        let context = Unmanaged.passUnretained(watch).toOpaque()
        for selector in audibilitySelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(watch.device, &address, audibilityProc, context)
        }
    }

    /// A *stacked* aggregate: sound sent here plays on `listen` AND lands in the loopback driver,
    /// so the Mac can be recorded while the user still hears it. This is what
    /// `record-lecture.sh` builds, and without it "맥 소리" records pure silence.
    static func makeMultiOutput(name: String, listen: Device, loopback: Device) -> Device? {
        let uid = "com.dongeun.NotchAI.multiout.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsStackedKey: 1,       // 1 = multi-output
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: listen.uid,   // clock = what the ear hears
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: listen.uid, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: loopback.uid, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var id = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr,
              id != 0 else { return nil }
        return Device(id: id, name: name, uid: uid)
    }

    /// The Mac's current default input — the built-in mic, unless the user changed it.
    static func defaultInput() -> Device? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return Device(id: id, name: name(of: id), uid: uid(of: id))
    }

    // MARK: - Aggregate

    /// Builds a private input device that carries `main` and `extra` together, so one file holds
    /// both the room and the Mac. `main` is the clock; the other side gets drift compensation.
    /// Returns nil when the aggregate cannot be created.
    static func makeAggregate(name: String, main: Device, extra: Device) -> Device? {
        // A fresh UID every time: a stale one collides with a device still held by the system.
        let uid = "com.dongeun.NotchAI.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsStackedKey: 0,       // 0 = ordinary aggregate, not a multi-output
            kAudioAggregateDeviceIsPrivateKey: 0,       // AVCaptureDevice cannot see a private one
            kAudioAggregateDeviceMainSubDeviceKey: main.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: main.uid, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: extra.uid, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var id = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr,
              id != 0 else { return nil }
        return Device(id: id, name: name, uid: uid)
    }

    @discardableResult
    static func destroyAggregate(_ device: Device) -> Bool {
        AudioHardwareDestroyAggregateDevice(device.id) == noErr
    }

    /// Removes aggregates this app made and did not clean up — after a crash, say. Safe to call
    /// at launch: it only touches devices carrying our own prefix.
    static func removeStaleAggregates() {
        // If a crash left the Mac listening through one of ours, put the sound back first —
        // otherwise destroying it drops audio output entirely.
        if let current = defaultOutput(), current.name.hasPrefix(aggregatePrefix) {
            let real = all().first {
                !$0.name.hasPrefix(aggregatePrefix)
                    && !$0.name.localizedCaseInsensitiveContains(loopbackNeedle)
                    && channelCount(of: $0.id, scope: kAudioObjectPropertyScopeOutput) > 0
            }
            if let real { setDefaultOutput(real) }
        }
        for device in all() where device.name.hasPrefix(aggregatePrefix) {
            _ = AudioHardwareDestroyAggregateDevice(device.id)
        }
    }

    // MARK: - Property reading

    private static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { Device(id: $0, name: name(of: $0), uid: uid(of: $0)) }
    }

    static func channelCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of device: AudioDeviceID) -> String {
        string(device, kAudioObjectPropertyName)
    }

    private static func uid(of device: AudioDeviceID) -> String {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeUnretainedValue() as String
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }
}
