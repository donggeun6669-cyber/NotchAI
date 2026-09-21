import SwiftUI

/// One provider at a glance: the character doing what the agent is doing, the session it is on,
/// how many are running, and how much of the plan is gone. Both cards are always shown, framed.
struct AgentCardView: View {
    let provider: any AIProvider

    /// Big enough for the character to have arms and show them.
    static let characterSize: CGFloat = 46

    var body: some View {
        let overview = provider.overview
        let accent = provider.kind.accent

        HStack(alignment: .top, spacing: 11) {
            AICharacterView(kind: provider.kind, state: provider.displayState, size: Self.characterSize)
                .frame(width: Self.characterSize, height: Self.characterSize)
                .padding(.top, 8)
                .padding(.horizontal, 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .tracking(0.1)
                        .foregroundStyle(accent)
                    StatusLabel(state: provider.displayState, accent: accent, fontSize: 10.5, showsDot: false)
                    Spacer(minLength: 4)
                    Text("작업 \(overview.runningCount) · 대기 \(overview.recentIdleCount())")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .tracking(0.2)
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize()
                        .help("작업 중인 세션 / 최근 1시간 안에 쓴 대기 세션")
                }

                HStack(spacing: 6) {
                    Text(overview.currentTitle ?? "열린 세션 없음")
                        .font(.system(size: 12.5))
                        .tracking(0.1)
                        .foregroundStyle(.white.opacity(overview.currentTitle == nil ? 0.35 : 0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if overview.subagentsRunning > 0 {
                        Text("+ 서브에이전트 \(overview.subagentsRunning)")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(accent.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(accent.opacity(0.15)))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .help(overview.sessions.sorted { $0.updatedAt > $1.updatedAt }
                    .map { session in
                        let quiet = !session.isBusy && Date.now.timeIntervalSince(session.updatedAt) >= AgentOverview.recentWindow
                        return (session.isBusy ? "● " : "○ ") + session.title + (quiet ? " (1시간 넘게 조용함)" : "")
                    }
                    .joined(separator: "\n"))

                UsageBlock(usage: overview.usage, isRefreshing: provider.isRefreshingUsage,
                           onRefresh: provider.refreshUsage)
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .stroke(LinearGradient(colors: [accent.opacity(0.5), accent.opacity(0.18)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.9)
        }
    }
}

/// The two windows stacked, each on its own line, so the numbers are readable at a glance.
private struct UsageBlock: View {
    let usage: AgentOverview.Usage?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let usage {
                    UsageBar(label: "5시간", percent: usage.shortWindowPercent, resetsAt: usage.shortWindowResetsAt)
                    UsageBar(label: "주간", percent: usage.weeklyPercent, resetsAt: usage.weeklyResetsAt)
                } else {
                    Text(isRefreshing ? "사용량 읽는 중…" : "사용량: ↻를 누르면 읽어옵니다")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(isRefreshing ? "읽는 중…" : usage.map { Self.age(of: $0.observedAt) } ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize()
                    .help("이 시각에 읽은 사용량입니다")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(isRefreshing ? 0.2 : 0.5))
                        .rotationEffect(.degrees(isRefreshing ? 180 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: isRefreshing)
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("지금 사용량 다시 읽기 (아주 짧은 요청 1번, 구독 사용량이 조금 듭니다)")
            }
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
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 26, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color(value)).frame(width: geometry.size.width * value / 100)
                }
            }
            .frame(height: 5)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
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
