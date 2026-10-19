import AppKit
import SwiftUI

/// The recorder, always in the top-right of the open notch (2026-10-19): the four situations,
/// the device, and the 3-second input check, without opening a separate screen first.
/// Its height follows what it shows; the sites below take the rest of the column.
struct RecordPanel: View {
    let recorder: RecorderService
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("녹음")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if recorder.isRunning {
                    Circle().fill(NotchPalette.red).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.open(RecorderService.folder)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("녹음 파일이 저장되는 폴더를 엽니다")
            }

            modeGrid

            Text(recorder.mode.explanation)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            device

            controlAndStatus
                .padding(.top, 1)
        }
        .onAppear { recorder.reloadDevices() }
    }

    // MARK: Situations

    private static func shortLabel(_ mode: RecorderService.Mode) -> String {
        switch mode {
        case .classroom: "강의실"
        case .onlineSpeakers: "스피커"
        case .onlineAirPods: "에어팟"
        case .onlineMuted: "무음"
        }
    }

    private var modeGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
            ForEach(RecorderService.Mode.allCases) { mode in
                let selected = recorder.mode == mode
                Button {
                    recorder.mode = mode
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? accent : .white.opacity(0.45))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.shortLabel(mode))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(selected ? 0.96 : 0.68))
                            Text(mode == .classroom ? "주변 소리" : "맥 소리")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.white.opacity(selected ? 0.5 : 0.3))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(selected ? 0.11 : 0.045))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selected ? accent.opacity(0.75) : .white.opacity(0.07), lineWidth: 1)
                            }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(recorder.isBusy)
                .opacity(recorder.isBusy && !selected ? 0.32 : 1)
                .help(mode.label + " — " + mode.explanation)
            }
        }
    }

    @ViewBuilder
    private var device: some View {
        HStack(spacing: 5) {
            if recorder.mode.usesMicrophone {
                Image(systemName: "mic")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
                microphonePicker
            } else {
                Image(systemName: recorder.readinessTrouble == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(recorder.readinessTrouble == nil ? Color.green.opacity(0.8) : accent)
                Text(recorder.sourceSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.2)))
    }

    /// Which microphone: the default, AirPods, an interface. Only shown when the mode uses one.
    private var microphonePicker: some View {
        Menu {
            Button {
                recorder.microphoneUID = nil
            } label: {
                Label("기본 입력 장치", systemImage: recorder.microphoneUID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(recorder.microphones) { device in
                Button {
                    recorder.microphoneUID = device.uid
                } label: {
                    Label(device.name, systemImage: recorder.microphoneUID == device.uid ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(recorder.chosenMicrophone?.name ?? "마이크 없음")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(recorder.isBusy)
        .help("어느 마이크로 받을지 고릅니다 (에어팟 포함)")
    }

    // MARK: Control

    @ViewBuilder
    private var controlAndStatus: some View {
        switch recorder.phase {
        case .checkingInput:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("입력 확인 중 · \(max(1, 3 - Int(recorder.elapsed)))초")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 0)
                    LevelMeter(level: recorder.level)
                }
                HStack {
                    Text(recorder.mode == .classroom ? "지금 한마디 말해 주세요"
                         : recorder.mode == .onlineMuted ? "강의를 재생해 주세요 · 소리는 나지 않습니다"
                         : "지금 강의를 재생해 주세요")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                    Button("취소") { recorder.stop() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        case .recording:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(NotchPalette.red).frame(width: 8, height: 8)
                    Text(RecorderService.clock(Int(recorder.elapsed)))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .monospacedDigit()
                    LevelMeter(level: recorder.level)
                    Spacer(minLength: 0)
                    Button("정지") { recorder.stop() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.8)))
                }
                if recorder.silenceAlarm {
                    warning(recorder.trouble?.message ?? "🔴 30초 동안 소리가 없습니다. 입력 장치를 확인해 주세요.")
                } else {
                    Text(recorder.mode == .onlineMuted ? "입력 확인 완료 · 음소거 키를 눌러도 계속 녹음"
                         : "입력 확인 완료 · 파일 길이도 매초 감시")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.green.opacity(0.72))
                        .lineLimit(1)
                }
            }
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("파일을 닫고 검증하는 중…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        default:
            idleControls
        }
    }

    @ViewBuilder
    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let trouble = recorder.trouble ?? recorder.readinessTrouble {
                warning(trouble.message)
            } else if let check = recorder.lastCheck {
                resultBadge(check)
            }
            startButton
                .help(recorder.mode == .classroom ? "시작 후 3초 동안 말하면 실제 입력을 확인합니다"
                      : recorder.mode == .onlineMuted ? "맥을 음소거한 채 강의를 재생하고 누르세요 · 소리는 파일에만 담깁니다"
                      : "강의를 먼저 재생한 뒤 누르면 3초 동안 실제 소리를 확인합니다")
        }
    }

    private var startButton: some View {
        Button { recorder.start() } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                Text("3초 확인 후 녹음")
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(recorder.canStart ? 0.96 : 0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Capsule().fill(accent.opacity(recorder.canStart ? 0.82 : 0.24)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!recorder.canStart)
    }

    private func resultBadge(_ check: RecordingCheck) -> some View {
        HStack(spacing: 6) {
            Text(check.summary)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(check.isClean ? .green.opacity(0.78) : accent)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(RecorderService.clock(check.expectedSeconds)) · 파일 \(RecorderService.clock(check.fileSeconds))")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.32))
                .monospacedDigit()
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(NotchPalette.red.opacity(0.95))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Eight bars that fill with the input level, so a dead input shows up immediately.
struct LevelMeter: View {
    let level: Double
    private static let bars = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                let threshold = Double(index + 1) / Double(Self.bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level >= threshold ? NotchPalette.red.opacity(0.85) : Color.white.opacity(0.14))
                    .frame(width: 3, height: 4 + CGFloat(index) * 1.4)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel("입력 레벨")
    }
}
