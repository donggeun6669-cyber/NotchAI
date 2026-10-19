import AppKit
import ServiceManagement
import SwiftUI

/// NotchDesk's `…` menu: displays, permissions, the recordings folder, login, quit.
struct MoreMenu: View {
    let app: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var allScreens = NotchWindowController.showsOnAllScreens

    var body: some View {
        Menu {
            Toggle("모든 모니터에 표시", isOn: Binding(
                get: { allScreens },
                set: { value in
                    NotchWindowController.showsOnAllScreens = value
                    allScreens = value
                }))
                .help("끄면 노치가 있는 내장 화면에만 표시합니다")
            Toggle("로그인할 때 자동으로 열기", isOn: Binding(
                get: { launchAtLogin },
                set: { enable in
                    do {
                        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("NotchDesk: launch at login failed: \(error)")
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            Divider()
            Button("녹음 폴더 열기") {
                try? FileManager.default.createDirectory(at: RecorderService.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(RecorderService.folder)
            }
            Button("권한 다시 요청하기 (재생 버튼 · 크롬 · 클립보드)") { Permissions.requestAll() }
            Button("캘린더 권한 설정 열기") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("NotchDesk 종료") { NSApp.terminate(nil) }
                .disabled(app.desk.recorder.isBusy)
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
