import AppKit
import ServiceManagement
import SwiftUI

/// NotchAI's `…` menu, beside the recorder: which parts of the notch are shown (all but the recorder
/// and Jarvis start hidden, 2026-11-01), the Jarvis address, the Claude settings while Claude is
/// shown, displays, permissions, login, quit.
struct MoreMenu: View {
    let app: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var allScreens = NotchWindowController.showsOnAllScreens

    var body: some View {
        Menu {
            Section("노치에 보이기") {
                ForEach(NotchFeatures.Feature.allCases) { feature in
                    Toggle(feature.label, isOn: Binding(
                        get: { app.features.isOn(feature) },
                        set: { app.features.set(feature, $0) }))
                }
            }
            Button(app.jarvis.isEnabled ? "Jarvis 주소… (\(app.jarvis.baseURL?.host ?? ""))" : "Jarvis 연결하기…") {
                JarvisAddressPrompt.ask(app.jarvis)
                app.resizePanels()
                NSApp.deactivate()
            }
            Divider()
            if app.features.isOn(.agents),
               let claude = app.providers.first(where: { $0.kind == .claude }) as? ClaudeProvider {
                Picker("Claude model", selection: Binding(get: { claude.model }, set: { claude.model = $0 })) {
                    ForEach(ClaudeProvider.Model.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                if ClaudeHookInstaller.isInstalled {
                    Text("Claude approval alerts: on")
                } else {
                    Button("Enable Claude approval alerts…") {
                        ClaudeHookInstaller.askAndInstall()
                        NSApp.deactivate()
                    }
                }
                Divider()
            }
            Toggle("모든 모니터에 표시", isOn: Binding(
                get: { allScreens },
                set: { value in
                    NotchWindowController.showsOnAllScreens = value
                    allScreens = value
                }))
                .help("끄면 노치가 있는 내장 화면에만 표시합니다")
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
