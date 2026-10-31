import AppKit
import SwiftUI

/// Jarvis in the open notch (2026-11-01): its light and state, the latest few jobs, and a button
/// to open Jarvis. Sits above Claude and GPT in the right column; the height is fixed so the
/// column does not jump when the state changes.
struct JarvisSection: View {
    let jarvis: JarvisService

    static let height: CGFloat = 74

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            switch jarvis.connection {
            case .off:
                EmptyView()
            case .checking:
                note("연결 확인 중…")
            case .offline(let reason):
                offline(reason)
            case .online:
                jobList
            }
        }
        .frame(height: Self.height, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if let orb = JarvisOrbState(jarvis.connection) {
                JarvisOrbView(state: orb, size: 13)
                    .frame(width: 13, height: 13)
            }
            Text("Jarvis")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JarvisOrbView.blue.opacity(jarvis.presence == nil ? 0.55 : 1))
            Text(Self.stateLine(jarvis.connection))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(stateColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let voice = jarvis.voice {
                // Push-to-talk lands here with the voice step: held down while talking.
                Button {
                    voice.isTalking ? voice.stopTalking() : voice.startTalking()
                } label: {
                    Image(systemName: voice.isTalking ? "mic.fill" : "mic")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jarvis에게 말하기")
            }
            Button {
                jarvis.openApp()
            } label: {
                HStack(spacing: 3) {
                    Text("열기")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Jarvis 앱을 브라우저에서 엽니다 (Tailscale 안에서만 열립니다)")
        }
        .help(headerHelp)
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
            if presence.approvals > 0 { parts.append("승인 \(presence.approvals)") }
            return parts.joined(separator: " · ")
        }
    }

    private var stateColor: Color {
        switch jarvis.connection {
        case .online(let presence) where presence.shownState == .needsApproval:
            Color(nsColor: CharacterState.attentionYellow)
        case .online(let presence) where presence.shownState == .idle:
            .white.opacity(0.42)
        case .online:
            .white.opacity(0.78)
        default:
            .white.opacity(0.42)
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

    // MARK: Body

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if jarvis.jobs.isEmpty {
                note("아직 맡긴 일이 없습니다")
            }
            ForEach(jarvis.jobs) { job in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.statusColor(job.status))
                        .frame(width: 5, height: 5)
                    Text(job.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(job.statusWord)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Self.statusColor(job.status).opacity(0.95))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: 15)
                .help(job.createdAt.map { "\(job.title)\n맡긴 때 \(ShortTime.ago($0))" } ?? job.title)
            }
        }
    }

    private func offline(_ reason: JarvisOffline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reason.explanation)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
            Button("다시 연결") { jarvis.askNow() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.38))
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
