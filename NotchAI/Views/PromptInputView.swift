import SwiftUI

/// One-line command field. Enter sends; Esc closes the panel.
struct PromptInputView: View {
    let provider: any AIProvider
    let chrome: ChromeService
    @Binding var text: String
    /// Changes when something outside asks for focus (e.g. "put in command").
    let focusRequestedAt: Date?
    let onSend: (String) -> Void
    /// Reports whether the panel should stay open (something is typed).
    let onFocusChange: (Bool) -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !provider.isRunningCommand
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("\(provider.name)에게 메시지…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand {
                    focused = false
                    onDismiss()
                }

            if chrome.isAvailable {
                ChromeChip(chrome: chrome, accent: provider.kind.accent)
            }

            if provider.isRunningCommand {
                Button {
                    provider.cancelCommand()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(canSend ? provider.kind.accent : .white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.08))
                .stroke(focused ? provider.kind.accent.opacity(0.6) : .white.opacity(0.1), lineWidth: 1)
        )
        // The panel stays open only while there is something typed — focus alone must not pin it
        // open, or it would never collapse after the field takes focus on its own.
        .onChange(of: focused) { onFocusChange(focused && !text.isEmpty) }
        .onChange(of: text) { onFocusChange(focused && !text.isEmpty) }
        .onChange(of: focusRequestedAt) { focused = true }
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        onSend(prompt)
        text = ""
        onFocusChange(false)
    }
}

/// Toggle that attaches the page Chrome is showing to the command.
private struct ChromeChip: View {
    @Bindable var chrome: ChromeService
    let accent: Color

    var body: some View {
        Button {
            chrome.attachesTab.toggle()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chrome.attachesTab ? accent : .white.opacity(0.35))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(accent.opacity(chrome.attachesTab ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chrome.attachesTab
              ? "보고 있는 크롬 탭을 명령에 붙여 보냅니다: \(chrome.frontTab?.title ?? "탭 없음")"
              : "크롬에서 보고 있는 페이지를 명령에 붙이기")
    }
}
