import AppKit
import ServiceManagement
import SwiftUI

/// NotchAI's `…` menu: the Claude model, approval alerts, displays, permissions, login, quit.
struct MoreMenu: View {
    let app: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var allScreens = NotchWindowController.showsOnAllScreens

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
