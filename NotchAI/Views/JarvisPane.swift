import AppKit
import SwiftUI

/// Jarvis in the open notch (2026-11-01), where the calendar used to be: its light and state, the
/// jobs it is running, and a conversation — type, and the answer streams in as Jarvis writes it,
/// with the tool it is using shown while it works. 「앱에서 열기」 opens the full app. A talk
/// button appears beside it once voice exists (`JarvisService.voice`).
struct JarvisPane: View {
    let jarvis: JarvisService
    @Bindable var chat: JarvisChat
    /// The notch must stay open while the question is being typed.
    var onFocusChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            jobs
            Divider().overlay(.white.opacity(0.08))
            conversation
                .frame(maxHeight: .infinity)
            input
        }
        .onDisappear { onFocusChange(false) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            if let orb = JarvisOrbState(jarvis.connection) {
                JarvisOrbView(state: orb, size: 14)
                    .frame(width: 14, height: 14)
            }
            Text("Jarvis")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(JarvisOrbView.blue.opacity(jarvis.presence == nil ? 0.55 : 1))
            Text(chat.isAnswering ? "답하는 중" : Self.stateLine(jarvis.connection))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(stateColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let voice = jarvis.voice {
                // Push-to-talk lands here with the voice step.
                headerButton(voice.isTalking ? "mic.fill" : "mic", help: "Jarvis에게 말하기") {
                    voice.isTalking ? voice.stopTalking() : voice.startTalking()
                }
            }
            headerButton("square.and.pencil", help: "새 대화 (노치 대화는 하루 동안 이어집니다)") {
                chat.newConversation()
            }
            .disabled(chat.isAnswering)
            Button {
                jarvis.openApp()
            } label: {
                HStack(spacing: 3) {
                    Text("앱에서 열기")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Jarvis 앱을 브라우저에서 엽니다 (Tailscale 안에서만 열립니다)")
        }
        .help(headerHelp)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// "작업 중 · 진행 2 · 대기 1", "쉬는 중", "연결 안 됨".
    static func stateLine(_ connection: JarvisConnection) -> String {
        switch connection {
        case .off: return "꺼짐"
        case .checking: return "확인 중"
        case .offline: return "연결 안 됨"
        case .online(let presence):
            var parts = [presence.shownState.word]
            if presence.runningJobs > 0 { parts.append("진행 \(presence.runningJobs)") }
            if presence.queuedJobs > 0 { parts.append("대기 \(presence.queuedJobs)") }
            if presence.approvals > 0 { parts.append("결재 \(presence.approvals)") }
            return parts.joined(separator: " · ")
        }
    }

    private var stateColor: Color {
        if chat.isAnswering { return JarvisOrbView.blue.opacity(0.9) }
        switch jarvis.connection {
        case .online(let presence) where presence.shownState == .needsApproval:
            return Color(nsColor: CharacterState.attentionYellow)
        case .online(let presence) where presence.shownState == .idle:
            return .white.opacity(0.42)
        case .online:
            return .white.opacity(0.78)
        default:
            return .white.opacity(0.42)
        }
    }

    private var headerHelp: String {
        var lines = [jarvis.address]
        if let presence = jarvis.presence {
            if presence.isDerived { lines.append("상태는 작업 수로 계산했습니다 (서버에 /presence 없음)") }
            if let last = presence.lastEventAt { lines.append("마지막 활동 \(ShortTime.ago(last))") }
            if let version = presence.version { lines.append("서버 \(version)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Jobs and approvals

    @ViewBuilder
    private var jobs: some View {
        if let presence = jarvis.presence {
            VStack(alignment: .leading, spacing: 2) {
                if presence.approvals > 0 {
                    Button {
                        jarvis.openApp()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text("결재 \(presence.approvals)건이 기다립니다 — 앱에서 확인")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: CharacterState.attentionYellow))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(jarvis.jobs.prefix(2)) { job in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.statusColor(job.status))
                            .frame(width: 5, height: 5)
                        Text(job.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(job.statusWord)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Self.statusColor(job.status).opacity(0.95))
                            .fixedSize()
                    }
                    .frame(height: 14)
                    .help(job.createdAt.map { "\(job.title)\n맡긴 때 \(ShortTime.ago($0))" } ?? job.title)
                }
            }
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "running": JarvisOrbView.blue
        case "done": Color(nsColor: CharacterState.doneGreen)
        case "failed": Color(nsColor: CharacterState.errorRed)
        case "interrupted": Color(nsColor: CharacterState.attentionYellow)
        default: .white.opacity(0.45)
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        if case .offline(let reason) = jarvis.connection, chat.lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(reason.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Button("다시 연결") { jarvis.askNow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if chat.lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("무엇이든 물어보세요, 동근님.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text("노치에서 한 대화는 하루 동안 이어집니다 · 앱에서도 같은 대화를 볼 수 있어요")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.lines) { line in
                            JarvisBubble(line: line, answering: chat.isAnswering && line.id == chat.lines.last?.id)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(chat.lines.last?.id, anchor: .bottom) }
                .onChange(of: chat.lines.last?.text) { proxy.scrollTo(chat.lines.last?.id, anchor: .bottom) }
                .onChange(of: chat.lines.count) { proxy.scrollTo(chat.lines.last?.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let notice = chat.notice {
                Text(notice)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(NotchPalette.red.opacity(0.95))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                JarvisInputField(
                    text: $chat.draft,
                    placeholder: jarvis.presence == nil ? "Jarvis에 연결되면 말할 수 있어요" : "Jarvis에게 말하기",
                    isEnabled: jarvis.presence != nil,
                    onSubmit: { chat.send($0) },
                    onFocusChange: { typing in
                        onFocusChange(typing)
                        if typing { chat.warm() }
                    })
                if chat.isAnswering {
                    sendButton("stop.circle.fill", help: "답 멈추기") { chat.stop() }
                } else {
                    sendButton("arrow.up.circle.fill", help: "보내기 (Return)") { chat.send(nil) }
                        .disabled(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty || jarvis.presence == nil)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
        }
    }

    private func sendButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(JarvisOrbView.blue)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The question field. An AppKit field rather than SwiftUI's: when Return is pressed it hands over
/// exactly what is in the box, finishing a Korean syllable still being composed — the SwiftUI
/// field's binding could lag behind fast typing and sent a cut-off question (2026-11-01 test).
struct JarvisInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: (String) -> Void
    let onFocusChange: (Bool) -> Void

    final class Field: NSTextField {
        var onFocus: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus?(true) }
            return became
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: JarvisInputField
        init(_ parent: JarvisInputField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() { textView.unmarkText() }   // finish the syllable being typed
            let question = textView.string
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            textView.string = ""
            parent.text = ""
            parent.onSubmit(question)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onFocus = { [onFocusChange] in onFocusChange($0) }
        field.isEnabled = isEnabled
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 12)])
        // Push text in only when it changed outside the field: cleared after sending.
        if field.stringValue != text, field.currentEditor() == nil || text.isEmpty { field.stringValue = text }
    }
}

/// One message. The user's on the right in a soft bubble; Jarvis's on the left as plain text, with
/// what it is doing underneath while it writes.
private struct JarvisBubble: View {
    let line: JarvisChatLine
    let answering: Bool

    var body: some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 3) {
                if !line.text.isEmpty {
                    Text(line.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch line.state {
        case .streaming where answering:
            HStack(spacing: 5) {
                Text(line.step.map { "일하는 중 · \($0)" } ?? (line.text.isEmpty ? "생각 중" : "쓰는 중"))
                    .lineLimit(1)
                AnimatedDots(period: line.step == nil ? 1.2 : 0.8)
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(JarvisOrbView.blue.opacity(0.85))
        case .stopped:
            meta("멈춤")
        case .failed(let why):
            meta("끊김 · \(why)", color: NotchPalette.red.opacity(0.9))
        default:
            if !line.jobIDs.isEmpty { meta("팀에 맡긴 작업 \(line.jobIDs.count)건") }
        }
    }

    private func meta(_ text: String, color: Color = .white.opacity(0.4)) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The `…` menu's "Jarvis 주소" dialog. Empty hides Jarvis from the notch.
enum JarvisAddressPrompt {
    @MainActor
    static func ask(_ jarvis: JarvisService) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = jarvis.address
        field.placeholderString = JarvisSettings.example

        let alert = NSAlert()
        alert.messageText = "Jarvis 주소"
        alert.informativeText = "데스크탑 Jarvis 서버 주소입니다 (Tailscale Serve 주소). 이 맥에만 저장되고, Tailscale이 켜져 있어야 열립니다. 비우면 노치에서 Jarvis를 숨깁니다."
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, JarvisSettings.baseURL(text) == nil {
                let failed = NSAlert()
                failed.messageText = "주소를 알아볼 수 없습니다"
                failed.informativeText = "예: \(JarvisSettings.example)"
                failed.runModal()
                return
            }
            jarvis.address = text
        default:
            break
        }
    }
}
