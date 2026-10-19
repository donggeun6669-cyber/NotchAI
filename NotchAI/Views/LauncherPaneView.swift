import AppKit
import SwiftUI

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

/// The sites and folders worth one click, and the page each project is served at.
/// A tab in the bottom strip since the recorder took its old place (2026-10-19).
struct LauncherPane: View {
    let launcher: LauncherService
    var columns = 2

    /// One button per target: "DEAN" with two of them becomes "DEAN 폴더" and "DEAN 상황판".
    struct Entry: Identifiable {
        let name: String
        let target: LauncherService.Target
        var id: String { name + target.id }
    }

    var entries: [Entry] {
        launcher.items.flatMap { item in
            item.targets.map { target in
                Entry(name: item.targets.count == 1 ? item.name : "\(item.name) \(target.label)", target: target)
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
                      spacing: 2) {
                ForEach(entries) { entry in
                    Button {
                        launcher.open(entry.target)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: entry.target.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 12)
                            Text(entry.name)
                                .font(.system(size: 11))
                                .tracking(0.1)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(0.055)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.target.value)
                }
            }
            if launcher.items.isEmpty {
                Text("열 것이 없습니다 — 위 메뉴에서 목록을 만들 수 있습니다")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

struct LauncherMenu: View {
    let launcher: LauncherService

    var body: some View {
        Menu {
            Button("목록 편집 (launcher.json)") { launcher.openFile() }
            Button("파일 다시 읽기") { launcher.reload() }
            Divider()
            Button("기본 목록으로 다시 만들기") { launcher.rebuild() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// "방금" / "12분 전" / "3시간 전" / "2일 전".
enum ShortTime {
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 90 { return "방금" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)분 전" }
        if minutes < 60 * 24 { return "\(minutes / 60)시간 전" }
        return "\(minutes / (60 * 24))일 전"
    }
}

/// The launcher under the recorder in the right column (2026-10-19), with its own small title.
struct SitesPane: View {
    let launcher: LauncherService

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("자주 가는 곳")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
                LauncherMenu(launcher: launcher)
            }
            LauncherPane(launcher: launcher, columns: 2)
        }
    }
}
