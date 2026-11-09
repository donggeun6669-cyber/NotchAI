import SwiftUI

/// The line along the bottom of the open notch (2026-11-09): CPU, temperature, memory, network, the
/// numbers Stats used to show in the menu bar. One line across the full panel; two lines of two
/// when only the narrow right column is open. Digits are monospaced so the line does not jitter.
struct MonitorStrip: View {
    let monitor: SystemMonitor
    /// Two lines of two (the narrow panel without a left column).
    var stacked = false

    static let height: CGFloat = 22
    static let stackedHeight: CGFloat = 44
    /// The divider above the strip and the space around it.
    static let gap: CGFloat = 9

    var body: some View {
        Group {
            if stacked {
                // The narrow panel: the three short numbers on one line, the network on its own.
                VStack(spacing: 4) {
                    HStack(spacing: 0) { cpu; separator; temperature; separator; memory }
                    network
                }
            } else {
                // The network takes the width its two rates need; the other three share the rest.
                HStack(spacing: 0) {
                    cpu; separator; temperature; separator; memory; separator
                    network.fixedSize().layoutPriority(1).padding(.horizontal, 12)
                }
            }
        }
        .environment(\.monitorStripCompact, stacked)
        .frame(maxWidth: .infinity)
        .frame(height: stacked ? Self.stackedHeight : Self.height)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 12)
    }

    // MARK: Metrics

    private var cpu: some View {
        Metric(symbol: "cpu", label: "CPU", value: MonitorFormat.percent(monitor.cpu),
               alert: (monitor.cpu ?? 0) >= 0.9)
            .help("CPU 사용률 · 전체 코어 평균 (1초마다, 메뉴바 고양이와 같은 값)")
    }

    private var temperature: some View {
        let reading = monitor.temperature
        let hot: Bool = if case .celsius(let value, _) = reading { value >= 90 } else { false }
        return Metric(symbol: "thermometer.medium", label: "TEMP", value: MonitorFormat.temperature(reading),
                      dimmed: reading == nil || isUnavailable(reading), alert: hot)
            .help(temperatureHelp(reading))
    }

    private var memory: some View {
        let reading = monitor.memory
        let pressure = reading?.pressure
        return Metric(symbol: "memorychip", label: "RAM", value: MonitorFormat.percent(reading?.fraction),
                      alert: pressure == .critical, warning: pressure == .warning)
            .help(memoryHelp(reading))
    }

    @ViewBuilder private var network: some View {
        switch monitor.network {
        case .offline:
            Metric(symbol: "network.slash", label: "NET", value: "연결 없음", dimmed: true)
                .help("기본 경로를 가진 네트워크가 없어요 (연결 안 됨)")
        case .measuring(let interface):
            NetworkMetric(download: nil, upload: nil)
                .help("네트워크 · \(interface) · 재는 중")
        case .rates(let rates, let interface):
            NetworkMetric(download: rates.downloadBytesPerSecond, upload: rates.uploadBytesPerSecond)
                .help("실시간 전송 속도 · \(interface) 인터페이스의 바이트 카운터 변화량 (1초마다)")
        }
    }

    // MARK: Tooltips

    private func isUnavailable(_ reading: TemperatureReading?) -> Bool {
        if case .unavailable = reading { return true }
        return false
    }

    private func temperatureHelp(_ reading: TemperatureReading?) -> String {
        switch reading {
        case .celsius(let value, let sensors):
            String(format: "CPU 온도 %.1f°C · %@ CPU 코어 센서 %d개 중 가장 높은 값 (SMC, Stats 「Hottest CPU」와 같은 계산) · 3초마다",
                   value, monitor.chip, sensors)
        case .unavailable(let reason):
            "CPU 온도를 잴 수 없어요 · \(reason)"
        case nil:
            "CPU 온도 · 재는 중"
        }
    }

    private func memoryHelp(_ reading: MemoryReading?) -> String {
        guard let reading else { return "메모리 · 재는 중" }
        var text = "사용 \(MonitorFormat.gigabytes(reading.usedBytes)) / \(MonitorFormat.gigabytes(reading.totalBytes))"
            + " · 앱 \(MonitorFormat.gigabytes(reading.appBytes)) · 고정 \(MonitorFormat.gigabytes(reading.wiredBytes))"
            + " · 압축 \(MonitorFormat.gigabytes(reading.compressedBytes))"
        if let pressure = reading.pressure { text += " · 메모리 압력 \(pressure.label)" }
        return text + " (캐시는 사용에서 뺌, 활성 상태 보기와 같은 계산)"
    }
}

private struct MonitorStripCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The narrow panel's strip: no icons beside CPU · TEMP · RAM, so three fit on one line.
    var monitorStripCompact: Bool {
        get { self[MonitorStripCompactKey.self] }
        set { self[MonitorStripCompactKey.self] = newValue }
    }
}

/// 「[icon] CPU 12%」.
private struct Metric: View {
    @Environment(\.monitorStripCompact) private var compact
    let symbol: String
    let label: String
    let value: String
    var dimmed = false
    var alert = false
    var warning = false

    private var valueColor: Color {
        if alert { return NotchPalette.red }
        if warning { return Color(red: 1, green: 0.78, blue: 0.3) }
        return .white.opacity(dimmed ? 0.45 : 0.92)
    }

    var body: some View {
        HStack(spacing: 5) {
            if !compact {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 13)
            }
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 「↓ 1.2 MB/s ↑ 240 KB/s」 with each half in a fixed width, so the arrows do not move.
private struct NetworkMetric: View {
    let download: Double?
    let upload: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text("NET")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            half("arrow.down", download)
            half("arrow.up", upload)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func half(_ symbol: String, _ value: Double?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            Text(value.map(MonitorFormat.rate) ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(value == nil ? 0.45 : 0.92))
                .frame(width: 62, alignment: .leading)
        }
    }
}
