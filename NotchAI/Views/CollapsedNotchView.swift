import SwiftUI

/// The strip beside the physical notch: Claude on the left wing, GPT on the right, each with its
/// character and status. Nothing is drawn in the middle because the hardware notch covers it.
/// Also used as the header row of the expanded panel so the transition stays continuous.
struct CollapsedNotchView: View {
    let left: any AIProvider
    let right: any AIProvider
    /// A track that just started; shown for a few seconds on a side whose agent is idle.
    let track: NowPlayingService.Track?
    let notchWidth: CGFloat
    let height: CGFloat
    /// Both agents idle: only the two characters, in narrow wings.
    var compact = false

    var body: some View {
        let wing = compact ? NotchGeometry.compactWingWidth : NotchGeometry.wingWidth
        // The track peeks on the right if GPT is idle, otherwise on the left if Claude is.
        let trackOnRight = track != nil && right.status.state == .idle
        let trackOnLeft = track != nil && !trackOnRight && left.status.state == .idle

        HStack(spacing: 0) {
            WingView(provider: left, track: trackOnLeft ? track : nil, compact: compact)
                .frame(width: wing)
            Color.clear.frame(width: notchWidth)
            WingView(provider: right, track: trackOnRight ? track : nil, compact: compact)
                .frame(width: wing)
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: track)
    }
}

/// One side of the notch: character, then status (or a new track) when there is something to say.
private struct WingView: View {
    let provider: any AIProvider
    let track: NowPlayingService.Track?
    let compact: Bool

    var body: some View {
        let state = provider.status.state
        HStack(spacing: 6) {
            AICharacterView(kind: provider.kind, state: state, size: 16)
            if !compact {
                if let track {
                    HStack(spacing: 3) {
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .semibold))
                        Text(track.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
                } else if state != .idle {
                    StatusLabel(state: state, accent: provider.kind.accent, showsDot: false)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, compact ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .help("\(provider.name): \(state.label)")
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

/// State name, optionally after a colored dot; "Thinking" and "Working" get animated dots.
struct StatusLabel: View {
    let state: AgentState
    let accent: Color
    var fontSize: CGFloat = 11
    var showsDot = true

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle()
                    .fill(state.indicatorColor(accent: accent))
                    .frame(width: 6, height: 6)
            }
            Text(state.label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(showsDot ? .white.opacity(0.8) : state.indicatorColor(accent: accent).opacity(0.95))
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
