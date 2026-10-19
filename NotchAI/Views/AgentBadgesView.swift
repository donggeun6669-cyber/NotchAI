import AppKit
import SwiftUI

/// Claude and GPT in the bottom-right corner of the open notch: a big character each and whether
/// it is working — nothing more (2026-10-19). A click brings that app forward.
struct AgentBadges: View {
    let providers: [any AIProvider]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(providers, id: \.kind) { provider in
                Badge(provider: provider)
            }
        }
    }
}

private struct Badge: View {
    let provider: any AIProvider

    var body: some View {
        let state = provider.displayState
        let accent = provider.kind.accent
        Button {
            AgentApp.activate(provider.kind)
        } label: {
            HStack(spacing: 8) {
                AICharacterView(kind: provider.kind, state: state, size: 34)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.opacity(state == .idle ? 0.6 : 1))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.indicatorColor(accent: accent))
                            .frame(width: 5, height: 5)
                        Text(Self.word(state))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(state == .idle ? 0.38 : 0.75))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(state.isBusy ? accent.opacity(0.14) : .white.opacity(0.04))
                    .stroke(state.isBusy ? accent.opacity(0.45) : .white.opacity(0.06), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("\(provider.name) 앱 열기")
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    static func word(_ state: AgentState) -> String {
        switch state {
        case .idle: "쉬는 중"
        case .thinking, .working: "작업 중"
        case .waitingForApproval: "승인 대기"
        case .completed: "끝남"
        case .awaitingReply: "답 기다림"
        case .error: "오류"
        }
    }
}

/// The desktop apps the sessions belong to. Bringing the app forward is as close as the notch
/// can get: there is no way to open one particular session from outside.
enum AgentApp {
    static func bundleIDs(for kind: ProviderKind) -> [String] {
        switch kind {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .gpt: ["com.openai.codex", "com.openai.chat"]
        }
    }

    @MainActor
    static func activate(_ kind: ProviderKind) {
        for id in bundleIDs(for: kind) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
    }
}
