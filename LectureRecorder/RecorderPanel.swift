import AppKit
import SwiftUI

/// The menu bar window: pick the situation, check the input for three seconds, record.
/// Same flow and wording as NotchAI's 녹음 tab, laid out for a small popover.
struct RecorderPanel: View {
    let recorder: RecorderService
    private let red = Color(red: 0.851, green: 0.176, blue: 0.212)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("강의 녹음")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text(recorder.mode.usesMicrophone ? "주변 소리" : "맥 내부 소리")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }
            modeGrid
            deviceRow
            Divider()
            controls
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            recorder.reloadDevices()
            recorder.reloadRecents()
        }
    }

    // MARK: - Situation

    private var modeGrid: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                modeCard(.classroom)
                modeCard(.onlineMuted)
            }
            GridRow {
                modeCard(.onlineSpeakers)
                modeCard(.onlineAirPods)
            }
        }
    }

    private func modeCard(_ mode: RecorderService.Mode) -> some View {
        let selected = recorder.mode == mode
        return Button {
            recorder.mode = mode
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? red : .secondary)
                Text(mode.label)
                    .font(.system(size: 12, weight: .semibold))
                Text(mode.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .padding(9)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? red.opacity(0.10) : Color.primary.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(selected ? red.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(recorder.isBusy)
        .opacity(recorder.isBusy && !selected ? 0.4 : 1)
        .help(mode.explanation)
    }

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Text("사용 장치")
                .foregroundStyle(.secondary)
            if recorder.mode.usesMicrophone {
                Menu {
                    Button("기본 입력 장치") { recorder.microphoneUID = nil }
                    Divider()
                    ForEach(recorder.microphones) { device in
                        Button(device.name) { recorder.microphoneUID = device.uid }
                    }
                } label: {
                    Text(recorder.chosenMicrophone?.name ?? "마이크 없음")
                }
                .fixedSize()
            } else {
                Image(systemName: recorder.readinessTrouble == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(recorder.readinessTrouble == nil ? .green : red)
                Text(recorder.sourceSummary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    // MARK: - Start, progress, result

    @ViewBuilder
    private var controls: some View {
        switch recorder.phase {
        case .checkingInput:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("입력 확인 중 · \(max(1, 3 - Int(recorder.elapsed)))초")
                        .font(.system(size: 12, weight: .semibold))
                    Text(hintWhileChecking)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Meter(level: recorder.level, color: red)
                Button("취소") { recorder.stop() }
            }
        case .recording:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(red).frame(width: 9, height: 9)
                    Text(RecorderService.clock(Int(recorder.elapsed)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Meter(level: recorder.level, color: red)
                    Spacer(minLength: 0)
                    Button("녹음 정지") { recorder.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(red)
                }
                if recorder.silenceAlarm {
                    warning(recorder.trouble?.message ?? "30초 동안 소리가 없습니다. 입력 장치를 확인해 주세요.")
                } else {
                    Text(recorder.mode == .onlineMuted
                         ? "입력 확인 완료 · 음소거 키를 눌러도 녹음은 계속됩니다"
                         : "입력 확인 완료 · 파일 길이도 함께 감시합니다")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.green)
                }
            }
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("파일을 닫고 처음부터 끝까지 검증하는 중…")
                    .font(.system(size: 11.5))
            }
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                if let trouble = recorder.trouble ?? recorder.readinessTrouble {
                    warning(trouble.message)
                } else {
                    Text(hintBeforeStart)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button {
                        recorder.start()
                    } label: {
                        Label("3초 확인 후 녹음", systemImage: "waveform.circle.fill")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(red)
                    .controlSize(.large)
                    .disabled(!recorder.canStart)
                    Spacer(minLength: 0)
                    if let check = recorder.lastCheck {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(check.summary)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(check.isClean ? .green : red)
                            Text("녹음 \(RecorderService.clock(check.expectedSeconds)) · 파일 \(RecorderService.clock(check.fileSeconds))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var hintWhileChecking: String {
        switch recorder.mode {
        case .classroom: "지금 한마디 말해 주세요"
        case .onlineMuted: "지금 강의를 재생해 주세요 · 소리는 나지 않습니다"
        case .onlineSpeakers, .onlineAirPods: "지금 강의를 재생해 주세요"
        }
    }

    private var hintBeforeStart: String {
        switch recorder.mode {
        case .classroom: "시작 후 3초 동안 말하면 실제로 소리가 들어오는지 확인합니다."
        case .onlineMuted: "맥을 음소거한 채 강의를 재생하고 누르세요. 소리는 파일에만 담깁니다."
        case .onlineSpeakers, .onlineAirPods: "강의를 먼저 재생한 뒤 누르면 3초 동안 실제 소리를 확인합니다."
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(red)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Files and app

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !recorder.recents.isEmpty {
                Text("최근 녹음")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(recorder.recents.prefix(3)) { take in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([take.url])
                    } label: {
                        HStack {
                            Text(take.url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(RecorderService.duration(take.seconds))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("녹음 폴더 열기") {
                    try? FileManager.default.createDirectory(at: RecorderService.folder,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RecorderService.folder)
                }
                if recorder.isLoopbackMissing || AudioDevices.loopback() == nil {
                    Button("BlackHole 받기") {
                        NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!)
                    }
                    .help("온라인 강의(맥 소리) 녹음에 필요합니다. 설치 후 재부팅")
                }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
                    .disabled(recorder.isBusy)
                    .help(recorder.isBusy ? "녹음을 먼저 멈춰 주세요" : "강의녹음 종료")
            }
            .font(.system(size: 11))
        }
    }
}

private struct Meter: View {
    let level: Double
    let color: Color
    private static let bars = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                let threshold = Double(index + 1) / Double(Self.bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level >= threshold ? color : Color.primary.opacity(0.15))
                    .frame(width: 3, height: 5 + CGFloat(index) * 1.5)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel("입력 레벨")
    }
}
