import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Body of the expanded panel: both agents at a glance on top, then two columns — what they are
/// doing, and what to open — and the desk (today, music, clipboard, shelf, timer) at the bottom.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    /// Both agents are always on screen, so nothing here is "selected": the accent is the
    /// panel's own.
    private var accent: Color { ProviderKind.claude.accent }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(app.providers, id: \.kind) { item in
                    AgentCardView(provider: item)
                }
            }

            MainPaneView(app: app)
                .frame(maxHeight: .infinity)

            Divider().overlay(.white.opacity(0.12))

            DeskView(desk: app.desk, accent: accent,
                     onFocusChange: { notch.setKeepsOpen($0) })
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
                    .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
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

}

struct MoreMenu: View {
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
