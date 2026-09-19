import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Body of the expanded panel: both agents at a glance on top, a chat with the selected one in
/// the middle, the desk (today, music, clipboard, shelf) at the bottom.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    var body: some View {
        let provider = app.selected
        let status = provider.status

        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(app.providers, id: \.kind) { item in
                    AgentCardView(provider: item, isSelected: item.kind == app.selectedKind) {
                        app.selectedKind = item.kind
                    }
                }
            }

            HStack(spacing: 8) {
                Text("대화 · \(provider.name)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(provider.kind.accent)
                if let note = note(provider: provider) {
                    Text(note.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(note.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                FolderButton(provider: provider)
                Button {
                    provider.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(provider.chat.messages.isEmpty ? 0.25 : 0.6))
                }
                .buttonStyle(.plain)
                .disabled(provider.chat.messages.isEmpty || provider.isRunningCommand)
                .help("새 대화")
                MoreMenu(app: app)
            }

            ChatView(provider: provider)
                .frame(maxHeight: .infinity)

            PromptInputView(provider: provider,
                            chrome: app.desk.chrome,
                            text: $app.draft,
                            focusRequestedAt: app.focusRequestedAt,
                            onSend: { app.send($0) },
                            onFocusChange: { notch.setKeepsOpen($0) },
                            onDismiss: { notch.collapse() })

            Divider().overlay(.white.opacity(0.12))

            DeskView(desk: app.desk, accent: provider.kind.accent,
                     onInsert: { app.insertIntoDraft($0) },
                     onSend: { app.send($0) })
                .frame(height: 84)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(provider.kind.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(6)
            }
        }
        // Files dropped anywhere on the panel land on the shelf.
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for item in providers {
                    if let url = try? await item.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let decoded = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(decoded)
                    }
                }
                guard !urls.isEmpty else { return }
                app.desk.shelf.add(urls)
                app.desk.tab = .shelf
            }
            return true
        }
    }

    /// Setup problems (not logged in, CLI missing) for the chat header. Replies and errors of the
    /// notch conversation appear in the chat itself.
    private func note(provider: any AIProvider) -> (text: String, color: Color)? {
        guard let message = provider.availability.message, provider.availability != .checking else { return nil }
        return (message, Color(nsColor: CharacterState.attentionYellow).opacity(0.9))
    }
}

/// Shows which folder commands run in; click to pick another.
private struct FolderButton: View {
    let provider: any AIProvider

    var body: some View {
        Button {
            chooseFolder()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(provider.workingDirectory?.lastPathComponent ?? "Choose folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
            .frame(maxWidth: 130)
        }
        .buttonStyle(.plain)
        .help(provider.workingDirectory?.path ?? "Folder commands run in")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = provider.workingDirectory
        panel.prompt = "Use Folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            provider.workingDirectory = url
        }
        NSApp.deactivate()
    }
}

private struct MoreMenu: View {
    let app: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Menu {
            if let claude = app.providers.first(where: { $0.kind == .claude }) as? ClaudeProvider {
                Picker("Claude model", selection: Binding(get: { claude.model }, set: { claude.model = $0 })) {
                    ForEach(ClaudeProvider.Model.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
            }
            Divider()
            if ClaudeHookInstaller.isInstalled {
                Text("Claude approval alerts: on")
            } else {
                Button("Enable Claude approval alerts…") {
                    ClaudeHookInstaller.askAndInstall()
                    NSApp.deactivate()
                }
            }
            Button("권한 다시 요청하기 (재생 버튼 · 크롬 · 클립보드)") {
                Permissions.requestAll()
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { enable in
                    do {
                        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("NotchAI: launch at login failed: \(error)")
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            Divider()
            Button("Quit NotchAI") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
