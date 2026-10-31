import SwiftUI

/// The strip beside the physical notch (2026-11-01): the recorder on the left wing, Jarvis on the
/// right. Nothing is drawn in the middle because the hardware notch covers it. Narrow (a mark each)
/// until a recording runs or fails; then the wings widen for its clock and input level, or for the
/// failure — which stays until it is dismissed, because a silent first attempt once passed
/// unnoticed. Claude and GPT join the wings when they are switched on.
/// Also the header row of the open panel, so the transition stays continuous.
struct CollapsedNotchView: View {
    let app: AppModel
    let notchWidth: CGFloat
    let height: CGFloat
    let wingWidth: CGFloat
    let narrow: Bool

    var body: some View {
        let agents = app.features.isOn(.agents)
        let mark = RecordingMark(app.recorder)
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                RecordingMarkView(mark: mark, narrow: narrow)
                if agents { character(app.provider(.claude)) }
            }
            .frame(width: wingWidth)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 5) {
                if agents { character(app.provider(.gpt)) }
                if let pill = app.approvals.pill, !narrow {
                    ApprovalPill(pill: pill) { app.approvals.open() }
                } else if !narrow, mark.showsLevel {
                    LevelMeter(level: app.recorder.level)
                        .help("입력 레벨")
                }
                if let jarvis = JarvisOrbState(app.jarvis.connection) {
                    JarvisOrbView(state: jarvis, size: JarvisOrbLayout.collapsedSize)
                        .frame(width: JarvisOrbLayout.collapsedSize, height: JarvisOrbLayout.collapsedSize)
                        .overlay(alignment: .topTrailing) {
                            // Something waits for a decision: the one red mark beside the notch.
                            if (app.jarvis.presence?.approvals ?? 0) > 0 {
                                Circle().fill(StudioTheme.red).frame(width: 5, height: 5).offset(x: 2, y: -2)
                            }
                        }
                        .help("Jarvis: \(JarvisOrbLayout.word(jarvis))"
                              + ((app.jarvis.presence?.approvals ?? 0) > 0 ? " · 결재 \(app.jarvis.presence?.approvals ?? 0)건" : ""))
                }
            }
            .frame(width: wingWidth)
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.2), value: mark)
    }

    private func character(_ provider: any AIProvider) -> some View {
        AICharacterView(kind: provider.kind, state: provider.displayState, size: 16)
            .frame(width: 16, height: 16)
            .help("\(provider.name): \(provider.displayState.label)")
    }
}

/// 「결재 1건 · 보기 ›」 beside the notch for a while when a new item arrives (2026-11-01 5차 · 6차).
/// The wing widens for it like for a recording's clock; hovering opens the notch as always, and a
/// click on the pill opens the 결재 panel beside it.
struct ApprovalPill: View {
    let pill: JarvisApprovals.Pill
    let open: () -> Void

    var body: some View {
        Text("결재 \(pill.count)건 · 보기 ›")
            .font(StudioTheme.font(10.5, .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(Color(hex: 0x34363A)))
            .onTapGesture(perform: open)
            .help("눌러서 결재 패널 열기")
    }
}

/// What the recorder's wing says. Pure, so the choice of words is testable.
enum RecordingMark: Equatable {
    /// Nothing running and nothing wrong: a dim microphone.
    case ready
    /// The 3-second input check, with the seconds left.
    case checking(secondsLeft: Int)
    /// Recording, its clock, and whether the input has gone silent or the file is falling behind.
    case recording(seconds: Int, alarm: Bool)
    /// Closing and checking the file.
    case finishing
    /// The last attempt failed and nobody has dismissed it.
    case failed(String)

    @MainActor
    init(_ recorder: RecorderService) {
        self = Self.make(phase: recorder.phase, elapsed: recorder.elapsed, alarm: recorder.silenceAlarm,
                         trouble: recorder.trouble, needsAttention: recorder.needsAttention)
    }

    static func make(phase: RecorderService.Phase, elapsed: TimeInterval, alarm: Bool,
                     trouble: RecorderService.Trouble?, needsAttention: Bool) -> RecordingMark {
        switch phase {
        case .checkingInput:
            return .checking(secondsLeft: max(1, Int(RecorderService.startupCheckSeconds) - Int(elapsed)))
        case .recording:
            return .recording(seconds: Int(elapsed), alarm: alarm)
        case .finishing:
            return .finishing
        case .idle:
            guard needsAttention else { return .ready }
            switch trouble {
            case .deadInput?, .deadSystemAudio?: return .failed("녹음 안 됨")
            case .denied?: return .failed("권한 없음")
            case .captureBehind?: return .failed("저장 밀림")
            case nil: return .failed("파일 확인")   // the finished file failed its check
            default: return .failed("녹음 실패")
            }
        }
    }

    var showsLevel: Bool {
        switch self {
        case .checking, .recording: true
        default: false
        }
    }

    var help: String {
        switch self {
        case .ready: "녹음하지 않는 중"
        case .checking: "녹음 전 3초 입력 확인 중"
        case .recording(_, let alarm): alarm ? "녹음 중 · 소리가 안 들어오거나 저장이 밀립니다" : "녹음 중"
        case .finishing: "파일을 닫고 검증하는 중"
        case .failed: "마지막 녹음이 실패했습니다 · 노치를 열어 확인하세요"
        }
    }
}

private struct RecordingMarkView: View {
    let mark: RecordingMark
    let narrow: Bool

    var body: some View {
        Group {
            switch mark {
            case .ready:
                Image(systemName: "mic.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.32))
            case .checking(let left):
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: CharacterState.attentionYellow)).frame(width: 7, height: 7)
                    if !narrow { words("확인 \(left)") }
                }
            case .recording(let seconds, let alarm):
                HStack(spacing: 4) {
                    if alarm {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NotchPalette.red)
                    } else {
                        Circle().fill(NotchPalette.red).frame(width: 7, height: 7)
                    }
                    if !narrow {
                        words(RecorderService.clock(seconds), color: alarm ? NotchPalette.red : .white.opacity(0.92))
                    }
                }
            case .finishing:
                HStack(spacing: 4) {
                    Circle().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
                    if !narrow { words("저장 중", color: .white.opacity(0.6)) }
                }
            case .failed(let text):
                Text(narrow ? "!" : text)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(NotchPalette.red))
            }
        }
        .help(mark.help)
    }

    private func words(_ text: String, color: Color = .white.opacity(0.92)) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
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

/// The Jarvis light beside the notch: small enough to share the 32pt wing with a character.
enum JarvisOrbLayout {
    static let collapsedSize: CGFloat = 10

    static func word(_ state: JarvisOrbState) -> String {
        switch state {
        case .checking: "연결 확인 중"
        case .offline: "연결 안 됨"
        case .idle: "쉬는 중"
        case .thinking: "생각 중"
        case .working(let jobs): "작업 중 \(jobs)"
        case .listening: "듣는 중"
        case .speaking: "말하는 중"
        case .unknown: "알 수 없는 상태"
        }
    }
}
