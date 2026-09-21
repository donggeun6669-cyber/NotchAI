import SwiftUI

/// One provider at a glance: state, the session it is on, how many are running, and usage.
/// Both cards are always shown, both framed.
struct AgentCardView: View {
    let provider: any AIProvider

    var body: some View {
        let overview = provider.overview
        let accent = provider.kind.accent

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AICharacterView(kind: provider.kind, state: provider.displayState, size: 18)
                Text(provider.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent)
                StatusLabel(state: provider.displayState, accent: accent, fontSize: 10.5, showsDot: false)
                Spacer(minLength: 4)
                Text("작업 \(overview.runningCount) · 대기 \(overview.recentIdleCount())")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .help("작업 중인 세션 / 최근 1시간 안에 쓴 대기 세션")
            }

            HStack(spacing: 6) {
                Text(overview.currentTitle ?? "열린 세션 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(overview.currentTitle == nil ? 0.4 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if overview.subagentsRunning > 0 {
                    Text("+ 서브에이전트 \(overview.subagentsRunning)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(accent.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.15)))
                        .fixedSize()
                }
            }
            .help(overview.sessions.sorted { $0.updatedAt > $1.updatedAt }
                .map { session in
                    let quiet = !session.isBusy && Date.now.timeIntervalSince(session.updatedAt) >= AgentOverview.recentWindow
                    return (session.isBusy ? "● " : "○ ") + session.title + (quiet ? " (1시간 넘게 조용함)" : "")
                }
                .joined(separator: "\n"))

            UsageRow(usage: overview.usage, kind: provider.kind,
                     isRefreshing: provider.isRefreshingUsage, onRefresh: provider.refreshUsage)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.09))
                .stroke(accent.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct UsageRow: View {
    let usage: AgentOverview.Usage?
    let kind: ProviderKind
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let usage {
                UsageBar(label: "5시간", percent: usage.shortWindowPercent, resetsAt: usage.shortWindowResetsAt)
                UsageBar(label: "주간", percent: usage.weeklyPercent, resetsAt: usage.weeklyResetsAt)
                Spacer(minLength: 0)
                Text(isRefreshing ? "읽는 중…" : Self.age(of: usage.observedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .help("이 시각에 읽은 사용량입니다")
            } else {
                Text(isRefreshing ? "사용량 읽는 중…" : "사용량: ↻를 누르면 읽어옵니다")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isRefreshing ? 0.2 : 0.5))
                    .rotationEffect(.degrees(isRefreshing ? 180 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: isRefreshing)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help("지금 사용량 다시 읽기 (아주 짧은 요청 1번, 구독 사용량이 조금 듭니다)")
        }
    }

    /// "방금" / "12분 전" / "3시간 전".
    static func age(of date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 2 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        return "\(minutes / 60)시간 전"
    }
}

private struct UsageBar: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        let value = min(max(percent ?? 0, 0), 100)
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.45))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color(value)).frame(width: 44 * value / 100)
            }
            .frame(width: 44, height: 4)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
        }
        .help(resetsAt.map { "초기화: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? label)
    }

    private func color(_ value: Double) -> Color {
        switch value {
        case ..<60: Color(nsColor: CharacterState.doneGreen)
        case ..<85: Color(nsColor: CharacterState.attentionYellow)
        default: Color(nsColor: CharacterState.errorRed)
        }
    }
}
