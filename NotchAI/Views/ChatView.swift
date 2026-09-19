import SwiftUI

/// The notch conversation with the selected provider.
struct ChatView: View {
    let provider: any AIProvider

    var body: some View {
        let chat = provider.chat
        ScrollViewReader { scroller in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if chat.messages.isEmpty {
                        Text("\(provider.name)에게 물어보세요. 📁 \(provider.workingDirectory?.lastPathComponent ?? "홈") 폴더에서 실행됩니다.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.top, 4)
                    }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, accent: provider.kind.accent)
                            .id(message.id)
                    }
                    if provider.isRunningCommand && chat.messages.last?.role != .step {
                        HStack(spacing: 4) {
                            AnimatedDots(period: 1.0)
                        }
                        .padding(.leading, 4)
                        .id("typing")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: chat.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    scroller.scrollTo(chat.messages.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.last?.text) {
                scroller.scrollTo(chat.messages.last?.id, anchor: .bottom)
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatSession.Message
    let accent: Color

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(accent.opacity(0.28)))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack {
                Text(Self.markdown(message.text))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.08)))
                    .textSelection(.enabled)
                Spacer(minLength: 40)
            }
        case .step:
            Label(message.text, systemImage: "arrow.turn.down.right")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .padding(.leading, 4)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: CharacterState.errorRed))
                .lineLimit(3)
                .padding(.leading, 4)
        }
    }

    /// Bold, italics, code and links render; block markdown stays as plain lines.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
