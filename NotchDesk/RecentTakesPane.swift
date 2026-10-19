import AppKit
import SwiftUI

/// The two latest recordings in the bottom-right corner, each with 전사 → progress → 자막.
/// Transcription runs on this Mac with the model inside the app (whisper.cpp), as in 강의녹음.
struct RecentTakesPane: View {
    let recorder: RecorderService
    let transcriber: Transcriber
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("최근 녹음 · 받아 적기")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.35))
            if recorder.recents.isEmpty {
                Text("녹음이 끝나면 여기서 글로 받아 적을 수 있습니다")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.32))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recorder.recents.prefix(2)) { take in
                    row(take)
                }
            }
        }
        .onAppear { recorder.reloadRecents() }
    }

    private func row(_ take: RecorderService.Take) -> some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([take.url])
            } label: {
                HStack(spacing: 5) {
                    Text(Self.takeDate(take))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                    Text(RecorderService.duration(take.seconds))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(take.url.lastPathComponent)
            transcriptControl(take.url)
        }
    }

    @ViewBuilder
    private func transcriptControl(_ url: URL) -> some View {
        switch transcriber.job(for: url) {
        case .preparing?:
            ProgressView().controlSize(.mini)
        case .transcribing(let percent)?:
            HStack(spacing: 3) {
                Text("\(percent)%")
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    transcriber.cancel(url)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("받아 적기 취소")
            }
        case .failed(let why)?:
            chip("다시", filled: false) { transcriber.transcribe(url) }
                .help("받아 적지 못했습니다: \(why)")
        default:
            if transcriber.hasTranscript(url) {
                chip("글 열기", filled: false) { NSWorkspace.shared.open(Transcriber.transcriptURL(for: url)) }
                    .help("받아 적은 글(.txt)을 엽니다. 시간이 붙은 자막(.srt)도 같은 폴더에 있습니다")
            } else {
                chip("전사", filled: true) { transcriber.transcribe(url) }
                    .disabled(!transcriber.isAvailable || transcriber.modelState != .ready
                              || transcriber.isBusy || recorder.isBusy)
                    .help(recorder.isBusy ? "녹음이 끝난 뒤 받아 적을 수 있습니다"
                          : "이 맥 안에서 무료로 글로 받아 적습니다 (인터넷으로 보내지 않음)")
            }
        }
    }

    private func chip(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(filled ? accent.opacity(0.75) : .white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    /// "10/18 일 19:50", from when the recording started (the start is in the file name;
    /// the file's creation date is when it was finished).
    static func takeDate(_ take: RecorderService.Take) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let date = formatter.date(from: String(take.url.lastPathComponent.prefix(15))) ?? take.startedAt
        let calendar = Calendar.current
        formatter.dateFormat = "HH:mm"
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date)) "
            + CalendarPane.weekday(date) + " " + formatter.string(from: date)
    }
}
