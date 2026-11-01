import SwiftUI

/// Press and hold to talk to Jarvis; let go to stop (2026-11-01). Works on the light beside the notch,
/// on the light in the Jarvis section and on its microphone button.
struct HoldToTalk: ViewModifier {
    let voice: JarvisVoice
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        voice.press(.pointer)
                    }
                    .onEnded { _ in
                        pressing = false
                        voice.release(.pointer)
                    })
            .onDisappear {
                if pressing { pressing = false; voice.release(.pointer) }
            }
    }
}

extension View {
    func holdToTalk(_ voice: JarvisVoice) -> some View { modifier(HoldToTalk(voice: voice)) }
}

/// The few words beside the closed notch while a call does something: a red dot and 「듣는 중」
/// while held (the one red thing — the microphone is open), then 「생각 중」, 「말하는 중」, or a
/// short notice such as 「녹음 중엔 쉬어요」.
struct VoiceTag: View {
    let voice: JarvisVoice

    var body: some View {
        HStack(spacing: 4) {
            if let notice = voice.notice, voice.phase != .holding, voice.phase != .speaking {
                Text(notice.short)
                    .foregroundStyle(StudioTheme.notch.secondary)
            } else {
                switch voice.phase {
                case .holding:
                    Circle().fill(StudioTheme.red).frame(width: 6, height: 6)
                    Text("듣는 중").foregroundStyle(StudioTheme.notch.text)
                case .waiting:
                    Text("생각 중").foregroundStyle(StudioTheme.notch.secondary)
                case .speaking:
                    Text("말하는 중").foregroundStyle(StudioTheme.notch.text)
                case .idle:
                    EmptyView()
                }
            }
        }
        .font(StudioTheme.font(10.5, .semibold))
        .lineLimit(1)
        .fixedSize()
        .help(voice.notice?.text ?? VoiceWords.help(voice.phase))
        .animation(.easeInOut(duration: 0.15), value: voice.phase)
    }
}

enum VoiceWords {
    static func help(_ phase: JarvisVoice.Phase) -> String {
        switch phase {
        case .holding: "Jarvis가 듣고 있어요 · 다 말하면 떼세요"
        case .waiting: "Jarvis가 답을 생각하고 있어요"
        case .speaking: "Jarvis가 말하고 있어요 · 눌러서 끼어들 수 있어요"
        case .idle: "Jarvis 빛을 꾹 누른 채 말하세요"
        }
    }
}

/// The microphone in the Jarvis section's question field: hold to talk. Red while held.
struct HoldToTalkButton: View {
    let voice: JarvisVoice

    var body: some View {
        let holding = voice.phase == .holding
        Image(systemName: holding ? "mic.fill" : "mic")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(holding ? StudioTheme.red : StudioTheme.notch.secondary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(holding ? StudioTheme.red.opacity(0.16) : .clear))
            .holdToTalk(voice)
            .help("꾹 누른 채 말하고, 다 말하면 떼세요 (\(JarvisTalkKey.current == .off ? "단축키 없음" : "단축키 " + JarvisTalkKey.current.keys))")
            .animation(.easeOut(duration: 0.12), value: holding)
    }
}
