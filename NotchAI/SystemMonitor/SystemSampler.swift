/*
 SystemSampler.swift — NotchAI

 CPU, memory and network readings for the menu bar cat and the notch's monitor strip.

 The CPU and memory arithmetic is ported from SystemInfoKit 7.2.2 (CPURepository.swift and
 MemoryRepository.swift), which RunCat Neo uses for its runner speed:
   Copyright 2020 Takuto Nakamura
   Licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)

 Modified for NotchAI on 2026-11-09:
   - the formulas are pure functions over plain counters, so they can be unit-tested;
   - the network rate counts only the primary interface (SystemInfoKit adds every link-layer
     interface, so loopback and a VPN tunnel such as Tailscale's utun counted the same bytes
     twice), handles the 32-bit counters wrapping at 4 GB, and divides by the time that really
     passed instead of the nominal interval;
   - memory pressure is read from the kernel's own level, not only derived from page counts.
 */

import Darwin
import Foundation
import SystemConfiguration

// MARK: - CPU

/// Cumulative CPU ticks since boot, summed over all cores (`host_cpu_load_info`).
struct CPUTicks: Equatable, Sendable {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0

    /// The share of time spent busy between two readings, as SystemInfoKit computes it:
    /// (user + system) / (user + system + idle + nice), capped below 1. Nil when no time passed.
    static func usage(from old: CPUTicks, to new: CPUTicks) -> Double? {
        // The counters are 32-bit in the kernel; a wrap would make a difference negative.
        func diff(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : Double(b + (1 << 32) - a) }
        let user = diff(old.user, new.user)
        let system = diff(old.system, new.system)
        let idle = diff(old.idle, new.idle)
        let nice = diff(old.nice, new.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return min((user + system) / total, 0.999)
    }

    static func read() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }
}

// MARK: - Memory

/// Page counts from `host_statistics64(HOST_VM_INFO64)`.
struct MemoryPages: Equatable, Sendable {
    var active: Double = 0
    var inactive: Double = 0
    var speculative: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var purgeable: Double = 0
    var external: Double = 0
}

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "정상"
        case .warning: "주의"
        case .critical: "위험"
        }
    }
}

struct MemoryReading: Equatable, Sendable {
    /// Used memory as Activity Monitor counts it: app memory + wired + compressed.
    var usedBytes: Double
    var totalBytes: Double
    var appBytes: Double
    var wiredBytes: Double
    var compressedBytes: Double
    var pressure: MemoryPressure?

    var fraction: Double { totalBytes > 0 ? min(usedBytes / totalBytes, 0.999) : 0 }

    /// SystemInfoKit's arithmetic. File-backed pages (`external`) and purgeable pages are cache
    /// that macOS hands back the moment something needs it, so they are not "used".
    static func from(pages: MemoryPages, pageSize: Double, totalBytes: Double,
                     pressure: MemoryPressure?) -> MemoryReading {
        let cached = pages.purgeable + pages.external
        let app = max(pages.active + pages.inactive + pages.speculative - cached, 0)
        let used = app + pages.wired + pages.compressed
        return MemoryReading(usedBytes: used * pageSize, totalBytes: totalBytes, appBytes: app * pageSize,
                             wiredBytes: pages.wired * pageSize, compressedBytes: pages.compressed * pageSize,
                             pressure: pressure)
    }

    static func read() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let pages = MemoryPages(active: Double(stats.active_count), inactive: Double(stats.inactive_count),
                                speculative: Double(stats.speculative_count), wired: Double(stats.wire_count),
                                compressed: Double(stats.compressor_page_count),
                                purgeable: Double(stats.purgeable_count), external: Double(stats.external_page_count))
        return from(pages: pages, pageSize: Double(pageSize), totalBytes: Double(ProcessInfo.processInfo.physicalMemory),
                    pressure: readPressure())
    }

    /// The kernel's own verdict (what Activity Monitor colours its pressure graph by).
    private static func readPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(rawValue: Int(level))
    }
}

// MARK: - Network

/// Byte counters of one interface at one moment.
struct NetworkCounters: Equatable, Sendable {
    var interface: String
    var received: UInt64
    var sent: UInt64
    /// `CLOCK_MONOTONIC` seconds (it keeps counting while the Mac sleeps).
    var time: TimeInterval
}

struct NetworkRates: Equatable, Sendable {
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double

    /// Bytes per second between two readings of the same interface. Nil when the interface changed
    /// or no time passed (the caller then waits for the next reading instead of showing a spike).
    static func between(_ old: NetworkCounters, _ new: NetworkCounters) -> NetworkRates? {
        guard old.interface == new.interface else { return nil }
        let seconds = new.time - old.time
        guard seconds > 0.2 else { return nil }
        // `if_data` holds 32-bit counters: past 4 GB they start again from zero.
        func diff(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : Double(b + (1 << 32) - a) }
        return NetworkRates(downloadBytesPerSecond: diff(old.received, new.received) / seconds,
                            uploadBytesPerSecond: diff(old.sent, new.sent) / seconds)
    }
}

/// Reads which interface carries the default route, and its byte counters.
@MainActor
final class NetworkCounterReader {
    private let store = SCDynamicStoreCreate(nil, "NotchAI.SystemMonitor" as CFString, nil, nil)

    /// The interface macOS routes traffic through (Wi-Fi, Ethernet, a VPN that took the default
    /// route…), or nil when there is no connection at all.
    func primaryInterface() -> String? {
        guard let store else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    func read(interface: String) -> NetworkCounters? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data,
                  String(cString: entry.pointee.ifa_name) == interface else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            return NetworkCounters(interface: interface, received: UInt64(counters.ifi_ibytes),
                                   sent: UInt64(counters.ifi_obytes), time: SystemClock.seconds())
        }
        return nil
    }
}

enum SystemClock {
    /// Seconds on a clock that keeps running while the Mac sleeps.
    static func seconds() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
    }
}
