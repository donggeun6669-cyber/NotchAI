import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sites, folders and files worth one click. Right-click a button to take it off the list;
/// add more from the menu or by dropping them on the list (2026-10-19).
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
                    .contextMenu {
                        if let url = entry.target.url, url.isFileURL {
                            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Button("목록에서 삭제", role: .destructive) { launcher.remove(entry.target) }
                    }
                }
            }
            if launcher.items.isEmpty {
                Text("비어 있습니다 — 폴더·파일을 여기로 끌어다 놓거나 위 메뉴에서 추가하세요")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LauncherMenu: View {
    let launcher: LauncherService

    var body: some View {
        Menu {
            Button("폴더·파일 추가…") { Self.chooseFiles(into: launcher) }
            Button("웹사이트 추가…") { Self.askForWebsite(into: launcher) }
            Divider()
            Text("버튼을 우클릭하면 삭제할 수 있습니다")
            Divider()
            Button("목록 파일 직접 편집 (launcher.json)") { launcher.openFile() }
            Button("목록 파일 다시 읽기") { launcher.reload() }
            if LauncherService.hasDefaultList {
                Button("기본 목록으로 다시 만들기") { launcher.rebuild() }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("자주 가는 곳 추가 · 편집")
    }

    /// The standard Open panel, not modal: the notch keeps its clock and meters moving meanwhile.
    static func chooseFiles(into launcher: LauncherService) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "추가"
        panel.message = "자주 가는 곳에 넣을 폴더나 파일을 고르세요"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { launcher.add(urls) }
        }
    }

    /// A small dialog with a name and an address.
    static func askForWebsite(into launcher: LauncherService) {
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        name.placeholderString = "이름 (비워 두면 주소로)"
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        address.placeholderString = "주소 (예: naver.com)"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(name)
        fields.addSubview(address)

        let alert = NSAlert()
        alert.messageText = "웹사이트 추가"
        alert.accessoryView = fields
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = address
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !launcher.addWebsite(name: name.stringValue, address: address.stringValue) {
            let failed = NSAlert()
            failed.messageText = "주소를 알아볼 수 없습니다"
            failed.informativeText = "예: naver.com 또는 https://www.naver.com"
            failed.runModal()
        }
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
/// Folders, files and links dropped here are added to it.
struct SitesPane: View {
    let launcher: LauncherService
    @State private var isDropTarget = false

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
        .padding(isDropTarget ? 4 : 0)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTarget) { providers in
            Task { @MainActor in
                for item in providers {
                    if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                       let data = try? await item.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        launcher.add([url])
                    } else if let url = try? await item.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                              url.scheme?.hasPrefix("http") == true {
                        launcher.addWebsite(name: "", address: url.absoluteString)
                    }
                }
            }
            return true
        }
    }
}
