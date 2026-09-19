import SwiftUI

/// The strip beside the physical notch: character + provider on the left wing, status on the right.
/// Nothing is drawn in the middle because the hardware notch covers it.
/// Also used as the header row of the expanded panel so the transition stays continuous.
struct CollapsedNotchView: View {
    let provider: any AIProvider
    /// A track that just started; shown for a few seconds instead of the agent status.
    let track: NowPlayingService.Track?
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let state = provider.status.state
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                AICharacterView(kind: provider.kind, state: state, size: 16)
                Text(provider.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(provider.kind.accent)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: NotchGeometry.wingWidth)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let track {
                    HStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .semibold))
                        Text(track.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
                } else {
                    StatusLabel(state: state, accent: provider.kind.accent)
                }
            }
            .padding(.trailing, 14)
            .frame(width: NotchGeometry.wingWidth)
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: provider.kind)
        .animation(.easeInOut(duration: 0.25), value: track)
    }
}

/// Colored dot + state name; "Thinking" and "Working" get animated dots.
struct StatusLabel: View {
    let state: AgentState
    let accent: Color
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.indicatorColor(accent: accent))
                .frame(width: 6, height: 6)
            Text(state.label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .fixedSize()
            if state == .thinking || state == .working {
                AnimatedDots(period: state == .working ? 0.8 : 1.2)
            }
        }
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}
