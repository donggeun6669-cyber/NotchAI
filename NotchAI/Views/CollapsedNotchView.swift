import SwiftUI

/// The strip beside the physical notch: Claude on the left wing, GPT on the right, each with its
/// character and status. Nothing is drawn in the middle because the hardware notch covers it.
/// Also used as the header row of the expanded panel so the transition stays continuous; there it
/// is only the two characters, since the panel shows Claude and GPT big in its corner (2026-10-19).
struct CollapsedNotchView: View {
    let left: any AIProvider
    let right: any AIProvider
    /// A track that just started; shown for a few seconds on a side whose agent is idle.
    let track: NowPlayingService.Track?
    let notchWidth: CGFloat
    let height: CGFloat
    /// Both agents idle: only the two characters, in narrow wings.
    var compact = false
    /// The panel is open: just the characters, no status words.
    var iconsOnly = false

    var body: some View {
        let wing = compact ? NotchGeometry.compactWingWidth : NotchGeometry.wingWidth
        // The track peeks on the right if GPT is idle, otherwise on the left if Claude is.
        let trackOnRight = track != nil && right.displayState == .idle
        let trackOnLeft = track != nil && !trackOnRight && left.displayState == .idle

        HStack(spacing: 0) {
            WingView(provider: left, track: trackOnLeft ? track : nil, compact: compact, iconsOnly: iconsOnly)
                .frame(width: wing)
            Color.clear.frame(width: notchWidth)
            WingView(provider: right, track: trackOnRight ? track : nil, compact: compact, iconsOnly: iconsOnly)
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
    let iconsOnly: Bool

    var body: some View {
        let state = provider.displayState
        HStack(spacing: 6) {
            AICharacterView(kind: provider.kind, state: state, size: 16)
            if iconsOnly {
                Spacer(minLength: 0)
            } else if !compact {
                if let track {
                    HStack(spacing: 3) {
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .semibold))
                        Text(track.title)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .tracking(0.1)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
                } else if state != .idle {
                    StatusLabel(state: state, accent: provider.kind.accent, showsDot: false)
                        .transition(.opacity)
                } else if let note = IdleNote.text(for: provider) {
                    // While the other side works, "Idle" says nothing. Show what is actually
                    // worth knowing about the quiet one.
                    Text(note)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .tracking(0.2)
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .fixedSize()
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
                .font(.system(size: fontSize, weight: .medium, design: .rounded))
                .tracking(0.25)
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

/// What to put beside a resting agent. "Idle" is a state, not information: how many of its
/// sessions are still open, or how much of the plan is gone, is something to act on.
enum IdleNote {
    /// Sessions this old are no longer "open" in the user's head.
    static let recent: TimeInterval = 3600

    @MainActor
    static func text(for provider: any AIProvider, now: Date = .now) -> String? {
        note(waiting: provider.overview.recentIdleCount(now: now),
             weeklyPercent: provider.overview.usage?.weeklyPercent)
    }

    nonisolated static func note(waiting: Int, weeklyPercent: Double?) -> String? {
        if waiting > 0 { return "대기 \(waiting)" }
        if let weeklyPercent { return "주간 \(Int(weeklyPercent.rounded()))%" }
        return nil
    }
}
