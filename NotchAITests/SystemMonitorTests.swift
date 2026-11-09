import Foundation
import Testing
@testable import NotchAI

/// The monitor strip and the menu bar cat (2026-11-09).
struct SystemSamplerTests {
    @Test func cpuUsageIsBusyTicksOverAllTicks() throws {
        let old = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let new = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        // busy 60 + 20 = 80 of 60 + 20 + 100 + 20 = 200
        #expect(try #require(CPUTicks.usage(from: old, to: new)) == 0.4)
        #expect(CPUTicks.usage(from: old, to: old) == nil)   // no time passed: no number
        let allBusy = CPUTicks(user: 300, system: 50, idle: 800, nice: 50)
        #expect(CPUTicks.usage(from: old, to: allBusy) == 0.999)   // capped below 100%, as RunCat does
    }

    @Test func cpuTicksSurviveTheCounterWrapping() throws {
        let old = CPUTicks(user: UInt64(UInt32.max) - 9, system: 0, idle: 0, nice: 0)
        let new = CPUTicks(user: 10, system: 0, idle: 20, nice: 0)
        // 20 busy ticks across the wrap, 20 idle
        #expect(try #require(CPUTicks.usage(from: old, to: new)) == 0.5)
    }

    @Test func memoryLeavesCacheOut() {
        let pages = MemoryPages(active: 1000, inactive: 500, speculative: 100, wired: 300, compressed: 200,
                                purgeable: 50, external: 250)
        let reading = MemoryReading.from(pages: pages, pageSize: 16384, totalBytes: 16384 * 4000, pressure: .normal)
        // app = 1000 + 500 + 100 − (50 + 250) = 1300; used = 1300 + 300 + 200 = 1800 pages
        #expect(reading.appBytes == 1300 * 16384)
        #expect(reading.usedBytes == 1800 * 16384)
        #expect(reading.fraction == 0.45)
        #expect(reading.compressedBytes == 200 * 16384)
    }

    @Test func networkRatesUseTheRealElapsedTime() throws {
        let old = NetworkCounters(interface: "en0", received: 1_000, sent: 500, time: 10)
        let new = NetworkCounters(interface: "en0", received: 3_001_000, sent: 500_500, time: 12)
        let rates = try #require(NetworkRates.between(old, new))
        #expect(rates.downloadBytesPerSecond == 1_500_000)
        #expect(rates.uploadBytesPerSecond == 250_000)
    }

    @Test func networkRatesWaitAfterAnInterfaceChangeAndSurviveWrapping() throws {
        let wifi = NetworkCounters(interface: "en0", received: 10, sent: 10, time: 1)
        let ethernet = NetworkCounters(interface: "en7", received: 999, sent: 999, time: 2)
        #expect(NetworkRates.between(wifi, ethernet) == nil)   // no spike when the route moves

        let beforeWrap = NetworkCounters(interface: "en0", received: UInt64(UInt32.max) - 999, sent: 0, time: 1)
        let afterWrap = NetworkCounters(interface: "en0", received: 1_000, sent: 0, time: 2)
        #expect(try #require(NetworkRates.between(beforeWrap, afterWrap)).downloadBytesPerSecond == 2_000)
    }

    @Test func liveReadingsWorkOnThisMac() throws {
        _ = try #require(CPUTicks.read())
        let memory = try #require(MemoryReading.read())
        #expect(memory.totalBytes == Double(ProcessInfo.processInfo.physicalMemory))
        #expect(memory.fraction > 0 && memory.fraction < 1)
    }
}

struct SMCTemperatureTests {
    @Test func theRequestStructHasTheKernelsSize() {
        #expect(SMCTemperatureReader.keyDataSize == 80)
    }

    @Test func decodesAppleSiliconFloatsAndOldFixedPoint() {
        let flt = SMCTemperatureReader.fourCC("flt ")
        let bits = Float(41.5).bitPattern
        let le = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24)]
        #expect(SMCTemperatureReader.decode(type: flt, bytes: le) == 41.5)
        #expect(SMCTemperatureReader.decode(type: SMCTemperatureReader.fourCC("sp78"), bytes: [0x2E, 0x80]) == 46.5)
        #expect(SMCTemperatureReader.decode(type: SMCTemperatureReader.fourCC("ui8 "), bytes: [1]) == nil)
    }

    /// Stats 3.0.22's M5 list: 6 super cores and 12 performance cores.
    @Test func m5UsesStatsCoreSensors() throws {
        let keys = try #require(SMCTemperatureReader.cpuCoreKeys(forBrand: "Apple M5"))
        #expect(keys.count == 18)
        #expect(keys.first == "Tp00" && keys.last == "Tp0y")
        #expect(SMCTemperatureReader.cpuCoreKeys(forBrand: "Apple M5 Pro") == keys)
        #expect(SMCTemperatureReader.cpuCoreKeys(forBrand: "Apple M4 Max")?.contains("Te05") == true)
        // An unknown chip shows N/A rather than a guess.
        #expect(SMCTemperatureReader.cpuCoreKeys(forBrand: "Intel(R) Core(TM) i9") == nil)
        #expect(SMCTemperatureReader.cpuCoreKeys(forBrand: "Apple M9") == nil)
        if case .unavailable = SMCTemperatureReader(brand: "Apple M9").read() {} else {
            Issue.record("an unknown chip must not report a temperature")
        }
    }

    /// On this Mac the reading is a real core temperature or an honest N/A, never a made-up number.
    @Test func liveReadingIsPlausibleOrUnavailable() {
        switch SMCTemperatureReader().read() {
        case .celsius(let value, let sensors):
            #expect((10...120).contains(value))
            #expect(sensors > 0)
        case .unavailable:
            break
        }
    }
}

struct RunCatTests {
    /// RunCat Neo's RunnerService.updateRunnerSpeed: CPU% / 5, between 1 and 20.
    @Test func speedFollowsRunCatNeo() {
        #expect(RunCatSpeed.speed(cpu: 0) == 1)
        #expect(RunCatSpeed.speed(cpu: 0.03) == 1)
        #expect(RunCatSpeed.speed(cpu: 0.12) == 2.4)
        #expect(RunCatSpeed.speed(cpu: 0.5) == 10)
        #expect(abs(RunCatSpeed.speed(cpu: 0.999) - 19.98) < 0.001)
        #expect(RunCatSpeed.speed(cpu: 1.5) == 20)
        #expect(RunCatSpeed.secondsPerFrame(speed: 1) == 0.5)   // two frames a second at rest
        #expect(RunCatSpeed.secondsPerFrame(speed: 20) == 0.025)
    }

    @MainActor
    @Test func theCatsFramesShipWithTheApp() {
        let frames = RunCatStatusItem.loadFrames()
        #expect(frames.count == 5)
        for frame in frames {
            #expect(frame.size.height == 18)
            #expect(frame.size.width == 28)
            #expect(frame.isTemplate)
            // 2× pixels for Retina
            #expect(frame.representations.first?.pixelsHigh == 36)
        }
        #expect(Bundle.main.url(forResource: "RunCatNeo-LICENSE", withExtension: "txt") != nil)
    }
}

struct MonitorFormatTests {
    @Test func ratesReadLikeTheBrief() {
        #expect(MonitorFormat.rate(0) == "0 KB/s")
        #expect(MonitorFormat.rate(240_000) == "240 KB/s")
        #expect(MonitorFormat.rate(1_200_000) == "1.2 MB/s")
        #expect(MonitorFormat.rate(56_000_000) == "56 MB/s")
        #expect(MonitorFormat.rate(2_400_000_000) == "2.4 GB/s")
    }

    @Test func percentsAndTemperatures() {
        #expect(MonitorFormat.percent(0.123) == "12%")
        #expect(MonitorFormat.percent(nil) == "—")
        #expect(MonitorFormat.temperature(.celsius(46.4, sensors: 12)) == "46°")
        #expect(MonitorFormat.temperature(.unavailable("x")) == "N/A")
        #expect(MonitorFormat.temperature(nil) == "—")   // not measured yet is not 「cannot measure」
    }
}
