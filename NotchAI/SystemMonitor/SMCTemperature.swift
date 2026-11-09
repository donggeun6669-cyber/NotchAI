/*
 SMCTemperature.swift — NotchAI

 The CPU temperature for the notch's monitor strip, read from the System Management Controller
 the way Stats shows 「Hottest CPU」: the highest of the CPU core sensors, ignoring readings
 outside 10–120 °C (some chips report broken sensors).

 Which SMC keys are CPU core sensors on which chip comes from Stats (Modules/Sensors/values.swift,
 checked against 3.0.22 · commit 1a4a9a6, 2026-11-08):
   Copyright (c) 2019 Serhiy Mytrovtsiy · MIT License
 The reader itself is NotchAI's own: one IOKit user-client call per request, no helper tool,
 no administrator rights, nothing written to the SMC.
 */

import Foundation
import IOKit
import os

/// What the strip shows for temperature.
enum TemperatureReading: Equatable, Sendable {
    /// The hottest CPU core, and how many core sensors answered.
    case celsius(Double, sensors: Int)
    /// Not measurable here, and why (shown as N/A; the reason goes to the tooltip).
    case unavailable(String)
}

/// Talks to `AppleSMC`. Not thread-safe: `SystemMonitor` uses it from one serial queue only.
final class SMCTemperatureReader: @unchecked Sendable {
    /// Where the sensor list came from, for the tooltip: 「Apple M5 · CPU 코어 18개 중 최고」.
    let chip: String
    private let keys: [String]
    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: (size: UInt32, type: UInt32)] = [:]
    /// Keys that answered "no such key" once are not asked again.
    private var missing: Set<String> = []
    private let log = Logger(subsystem: "com.dongeun.NotchAI", category: "monitor")

    init(brand: String = SMCTemperatureReader.cpuBrand()) {
        chip = brand
        keys = Self.cpuCoreKeys(forBrand: brand) ?? []
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read() -> TemperatureReading {
        guard !keys.isEmpty else { return .unavailable("이 칩(\(chip))의 CPU 온도 센서 목록이 없어요") }
        guard open() else { return .unavailable("SMC에 연결하지 못했어요") }
        var values: [Double] = []
        for key in keys where !missing.contains(key) {
            switch value(of: key) {
            case .some(let celsius): values.append(celsius)
            case .none: continue
            }
        }
        let plausible = values.filter { (10...120).contains($0) }
        guard let hottest = plausible.max() else { return .unavailable("CPU 온도 센서가 답하지 않아요") }
        return .celsius(hottest, sensors: plausible.count)
    }

    /// The connection is opened lazily and again after a failure (for example after waking).
    private func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return false }
        connection = conn
        return true
    }

    private func reset() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
        keyInfo.removeAll()
    }

    // MARK: SMC protocol

    struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct Info { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var info = Info()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
    typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    /// The kernel's `SMCKeyData_t` is 80 bytes; a different size means this struct is wrong.
    static var keyDataSize: Int { MemoryLayout<KeyData>.stride }

    private static let kernelIndex: UInt32 = 2
    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9
    private static let keyNotFound: UInt8 = 0x84

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, Self.kernelIndex, &input, MemoryLayout<KeyData>.stride,
                                               &output, &outputSize)
        guard result == kIOReturnSuccess else {
            log.error("SMC call failed: \(result, privacy: .public)")
            reset()
            return nil
        }
        return output
    }

    private func value(of key: String) -> Double? {
        let code = Self.fourCC(key)
        var input = KeyData()
        input.key = code
        let info: (size: UInt32, type: UInt32)
        if let cached = keyInfo[code] {
            info = cached
        } else {
            input.command = Self.readKeyInfo
            guard let output = call(&input) else { return nil }
            if output.result == Self.keyNotFound { missing.insert(key); return nil }
            guard output.result == 0 else { return nil }
            info = (output.info.size, output.info.type)
            keyInfo[code] = info
        }
        input.info.size = info.size
        input.command = Self.readBytes
        guard let output = call(&input), output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
        return Self.decode(type: info.type, bytes: bytes)
    }

    /// Apple Silicon reports temperatures as little-endian floats (`flt `); older keys as `sp78`.
    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        switch type {
        case fourCC("flt ") where bytes.count >= 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case fourCC("sp78") where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: Which sensors

    static func cpuBrand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// The CPU core temperature keys Stats uses for 「Hottest CPU」 on each Apple Silicon generation.
    /// Pro / Max / Ultra share their generation's list (a key a chip lacks is simply skipped).
    /// An unknown chip gets nil: guessing could show a GPU or battery sensor as the CPU.
    static func cpuCoreKeys(forBrand brand: String) -> [String]? {
        guard let match = brand.firstMatch(of: /Apple M(\d+)/), let generation = Int(match.1) else { return nil }
        switch generation {
        case 1: return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case 2: return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case 3: return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case 4: return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case 5: return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",                      // super cores
                        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j",      // performance cores
                        "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        default: return nil
        }
    }
}
