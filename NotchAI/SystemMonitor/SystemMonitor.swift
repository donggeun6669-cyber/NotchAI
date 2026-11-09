import AppKit
import Foundation
import Observation
import os

/// One sampler for the menu bar cat and the notch's monitor strip (2026-11-09, replacing Stats and
/// RunCat Neo as separate apps). A single 1-second timer reads CPU, memory and network; the cat and
/// the strip both read the same values, so nothing is measured twice.
///
/// - CPU runs whenever the cat or the strip is on (the cat shows load even with the notch closed).
/// - Memory and network are cheap (a few microseconds) and are read with the CPU, so the strip has
///   current numbers the moment the notch opens; while it is closed no view reads them.
/// - Temperature (an SMC round trip, ~0.3 ms) is read every 3 seconds, only while a notch is open
///   with the strip on, on its own serial queue so the main thread never waits on the SMC.
/// - Asleep: the timer stops; on waking the baselines are dropped so the first numbers are not a
///   spike that covers the whole sleep.
@MainActor
@Observable
final class SystemMonitor {
    enum NetworkState: Equatable {
        /// No interface carries the default route: not connected (not the same as 0 B/s).
        case offline
        /// Connected; the first reading after a change has nothing to compare with yet.
        case measuring(interface: String)
        case rates(NetworkRates, interface: String)
    }

    private(set) var cpu: Double?
    private(set) var memory: MemoryReading?
    private(set) var network: NetworkState = .offline
    private(set) var temperature: TemperatureReading?

    /// Called with each new CPU share (0…1): the cat's speed.
    @ObservationIgnored var onCPU: ((Double) -> Void)?

    static let interval: TimeInterval = 1
    static let temperatureInterval: TimeInterval = 3

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: CPUTicks?
    @ObservationIgnored private var lastCounters: NetworkCounters?
    @ObservationIgnored private let networkReader = NetworkCounterReader()
    @ObservationIgnored private let smc = SMCTemperatureReader()
    @ObservationIgnored private let smcQueue = DispatchQueue(label: "com.dongeun.NotchAI.smc", qos: .utility)
    @ObservationIgnored private var lastTemperatureRead: TimeInterval = 0
    @ObservationIgnored private var temperatureInFlight = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var asleep = false

    /// Something needs the numbers: the cat, the strip, or both.
    @ObservationIgnored private var catOn = false
    @ObservationIgnored private var stripOn = false
    /// A notch with the strip is open on some screen.
    @ObservationIgnored private var stripVisible = false

    /// Which chip the temperature list is for (for the tooltip).
    var chip: String { smc.chip }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
    }

    /// What is switched on. Starts or stops the timer to match.
    func configure(cat: Bool, strip: Bool) {
        catOn = cat
        stripOn = strip
        if !strip { stripVisible = false }
        updateTimer()
    }

    /// Whether a notch showing the strip is open (asked 20 times a second while the cursor is near).
    func setStripVisible(_ visible: Bool) {
        let visible = visible && stripOn
        guard visible != stripVisible else { return }
        stripVisible = visible
        if visible { readTemperatureIfDue(force: true) }
    }

    private var isWanted: Bool { (catOn || stripOn) && !asleep }

    private func updateTimer() {
        if isWanted, timer == nil {
            tick()
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.15
            RunLoop.main.add(timer, forMode: .common)   // keeps counting while a menu is open
            self.timer = timer
        } else if !isWanted, let timer {
            timer.invalidate()
            self.timer = nil
            dropBaselines()
        }
    }

    private func sleep() {
        asleep = true
        updateTimer()
    }

    private func wake() {
        asleep = false
        dropBaselines()
        updateTimer()
    }

    private func dropBaselines() {
        lastTicks = nil
        lastCounters = nil
        if case .rates(_, let name) = network { network = .measuring(interface: name) }
    }

    private func tick() {
        if let ticks = CPUTicks.read() {
            if let last = lastTicks, let usage = CPUTicks.usage(from: last, to: ticks) {
                if cpu != usage { cpu = usage }
                onCPU?(usage)
            }
            lastTicks = ticks
        }
        guard stripOn else { return }

        let reading = MemoryReading.read()
        if reading != memory { memory = reading }

        readNetwork()
        readTemperatureIfDue(force: false)
    }

    private func readNetwork() {
        guard let interface = networkReader.primaryInterface(),
              let counters = networkReader.read(interface: interface) else {
            lastCounters = nil
            if network != .offline { network = .offline }
            return
        }
        let next: NetworkState
        if let last = lastCounters, let rates = NetworkRates.between(last, counters) {
            next = .rates(rates, interface: interface)
        } else {
            next = .measuring(interface: interface)
        }
        lastCounters = counters
        if next != network { network = next }
    }

    private func readTemperatureIfDue(force: Bool) {
        guard stripVisible, !temperatureInFlight else { return }
        let now = SystemClock.seconds()
        guard force || now - lastTemperatureRead >= Self.temperatureInterval - 0.2 else { return }
        lastTemperatureRead = now
        temperatureInFlight = true
        let smc = smc
        smcQueue.async { [weak self] in
            let reading = smc.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.temperatureInFlight = false
                    if reading != self.temperature { self.temperature = reading }
                }
            }
        }
    }
}

// MARK: - Formatting

enum MonitorFormat {
    /// 「12%」. Whole percent: the strip is glanced at, not read.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// 「46°」, 「N/A」 when it cannot be measured here, 「—」 before the first reading.
    static func temperature(_ reading: TemperatureReading?) -> String {
        switch reading {
        case .celsius(let value, _): "\(Int(value.rounded()))°"
        case .unavailable: "N/A"
        case nil: "—"
        }
    }

    /// 「1.2 MB/s」, 「240 KB/s」, 「0 KB/s」: decimal units, as Activity Monitor and Stats use.
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1000
        if kb < 1 { return "0 KB/s" }
        if kb < 999.5 { return String(format: "%.0f KB/s", kb) }
        let mb = kb / 1000
        if mb < 10 { return String(format: "%.1f MB/s", mb) }
        if mb < 1000 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.1f GB/s", mb / 1000)
    }

    /// 「15.1 GB」.
    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}
