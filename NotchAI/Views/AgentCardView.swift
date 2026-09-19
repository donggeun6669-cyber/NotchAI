import SwiftUI

/// One provider at a glance: state, the session it is on, how many are running, and usage.
/// Tapping a card makes it the chat target.
struct AgentCardView: View {
    let provider: any AIProvider
    let isSelected: Bool
    let onSelect: () -> Void

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

            UsageRow(usage: overview.usage, kind: provider.kind)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.09 : 0.05))
                .stroke(isSelected ? accent.opacity(0.55) : .white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct UsageRow: View {
    let usage: AgentOverview.Usage?
    let kind: ProviderKind

    var body: some View {
        if let usage {
            HStack(spacing: 10) {
                UsageBar(label: "5시간", percent: usage.shortWindowPercent, resetsAt: usage.shortWindowResetsAt)
                UsageBar(label: "주간", percent: usage.weeklyPercent, resetsAt: usage.weeklyResetsAt)
                Spacer(minLength: 0)
                Text(Self.age(of: usage.observedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .help("이 시각에 읽은 사용량입니다")
            }
        } else {
            Text(kind == .claude ? "사용량: 노치에서 한 번 대화하면 표시됩니다" : "사용량 기록 없음")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
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
