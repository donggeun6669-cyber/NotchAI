import SwiftUI

/// Root view: the black notch extension at the top center, sized to the current state, with the
/// two wings beside the hardware notch and, when open, the panel.
struct NotchView: View {
    let model: NotchViewModel
    let app: AppModel

    private var geometry: NotchGeometry { model.geometry }

    var body: some View {
        let size = model.currentSize
        // The island floats, so it has no ears growing out of the screen edge.
        let ear = geometry.isIsland ? 0 : NotchGeometry.earRadius
        let compact = !model.isExpanded && model.isCompact()

        ZStack(alignment: .top) {
            Group {
                if geometry.isIsland {
                    let island = RoundedRectangle(cornerRadius: model.isExpanded ? 24 : size.height / 2,
                                                  style: .continuous)
                    NotchBackdrop(shape: island, solidHeight: geometry.notchHeight,
                                  isExpanded: model.isExpanded)
                } else {
                    NotchBackdrop(shape: NotchShape(earRadius: ear, bottomRadius: model.isExpanded ? 22 : 10),
                                  solidHeight: geometry.notchHeight, isExpanded: model.isExpanded)
                }
            }
            .frame(width: size.width + ear * 2, height: size.height)
            .shadow(color: .black.opacity(geometry.isIsland ? 0.5 : (model.isExpanded ? 0.4 : 0)),
                    radius: geometry.isIsland ? 12 : 14, y: geometry.isIsland ? 4 : 6)

            VStack(spacing: 0) {
                DeskWings(app: app, notchWidth: geometry.notchRect.width, height: geometry.notchHeight,
                          compact: compact)
                if model.isExpanded {
                    ExpandedNotchView(app: app, notch: model)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + ear * 2, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture { model.expand() }
        .contextMenu {
            Button("NotchDesk 종료") { NSApp.terminate(nil) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.isExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: compact)
        .frame(width: geometry.windowFrame.width, height: geometry.windowFrame.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Beside the hardware notch: today's date on the left; on the right a recording's clock, or a
/// track that just started. With nothing running the wings stay narrow.
private struct DeskWings: View {
    let app: AppModel
    let notchWidth: CGFloat
    let height: CGFloat
    let compact: Bool

    var body: some View {
        let wing = compact ? NotchGeometry.compactWingWidth : NotchGeometry.wingWidth
        let recorder = app.desk.recorder
        let track = app.desk.peekingTrack
        let today = Calendar.current.component(.day, from: .now)
        let todayCount = app.calendar.items(on: .now).count

        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("\(today)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 15)
                    .background(Capsule().fill(NotchPalette.red))
                if !compact && todayCount > 0 {
                    Text("일정 \(todayCount)")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                }
                if !compact { Spacer(minLength: 0) }
            }
            .padding(.leading, compact ? 0 : 12)
            .frame(width: wing, alignment: compact ? .center : .leading)
            .help("오늘 일정 \(todayCount)개")

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 5) {
                if recorder.isRunning {
                    Circle()
                        .fill(NotchPalette.red)
                        .frame(width: 7, height: 7)
                        .overlay {
                            if recorder.silenceAlarm {
                                Circle().stroke(NotchPalette.red.opacity(0.5), lineWidth: 2).frame(width: 12, height: 12)
                            }
                        }
                    Text(recorder.phase == .checkingInput ? "확인 중" : RecorderService.clock(Int(recorder.elapsed)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize()
                } else if let track {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .semibold))
                    Text(track.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.leading, compact ? 0 : 12)
            .frame(width: wing, alignment: .leading)
            .help(recorder.isRunning ? "녹음 중" : "")
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: track)
    }
}
