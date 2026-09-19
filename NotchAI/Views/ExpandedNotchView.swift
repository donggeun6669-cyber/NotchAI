import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Body of the expanded panel: agent on top (character, status, activity, command field),
/// desk below (music, clipboard, shelf).
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    var body: some View {
        let provider = app.selected
        let status = provider.status

        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    AICharacterView(kind: provider.kind, state: status.state, size: 44, showsMark: true)
                        .padding(.top, 4)
                    ProviderSelector(selection: $app.selectedKind)
                }
                .frame(width: 112)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.system(size: 14, weight: .semibold))
                        StatusLabel(state: status.state, accent: provider.kind.accent)
                        Spacer(minLength: 4)
                        FolderButton(provider: provider)
                        MoreMenu(app: app)
                    }

                    Text(status.currentTask ?? "No active task")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(status.currentTask == nil ? 0.45 : 0.92))
                        .lineLimit(1)

                    if let note = note(provider: provider) {
                        Text(note.text)
                            .font(.system(size: 11))
                            .foregroundStyle(note.color)
                            .lineLimit(1)
                    }

                    ActivityListView(activities: status.activities, accent: provider.kind.accent)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 118)

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

    /// Setup problems first, then the latest result / error / approval message.
    private func note(provider: any AIProvider) -> (text: String, color: Color)? {
        if let message = provider.availability.message, provider.availability != .checking {
            return (message, Color(nsColor: CharacterState.attentionYellow).opacity(0.9))
        }
        let status = provider.status
        guard let detail = status.detail, !detail.isEmpty else { return nil }
        let color: Color = switch status.state {
        case .error: Color(nsColor: CharacterState.errorRed)
        case .waitingForApproval: Color(nsColor: CharacterState.attentionYellow)
        default: .white.opacity(0.6)
        }
        return (detail, color)
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
