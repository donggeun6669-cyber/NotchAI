import AppKit
import SwiftUI

/// The middle of the expanded notch, in two columns: what the agents are doing on the left,
/// the places worth opening on the right.
struct MainPaneView: View {
    let app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Column(title: "활동") {
                ActivityPane(app: app)
            }
            Divider().overlay(.white.opacity(0.08))
            Column(title: "실행", trailing: {
                HStack(spacing: 2) {
                    LauncherMenu(launcher: app.launcher)
                    MoreMenu(app: app)
                }
            }) {
                LauncherPane(launcher: app.launcher)
            }
            .frame(width: 236)
        }
    }
}

private struct Column<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                trailing
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - 활동

/// One row per open session of both agents, busy ones first.
private struct ActivityPane: View {
    let app: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(app.providers, id: \.kind) { provider in
                    ProviderSection(provider: provider)
                }
            }
        }
    }
}

private struct ProviderSection: View {
    let provider: any AIProvider
    /// More than this and the list stops being readable; the card above keeps the totals.
    static let maxRows = 4

    /// What the busy session is doing, when that is not just its own name again.
    static func detail(for session: AgentOverview.Session, provider: any AIProvider) -> String? {
        guard session.isBusy, let task = provider.status.currentTask, task != session.title else { return nil }
        return task
    }

    var body: some View {
        let sessions = provider.overview.sessions
            .sorted { $0.isBusy == $1.isBusy ? $0.updatedAt > $1.updatedAt : $0.isBusy }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(provider.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(provider.kind.accent)
                if provider.overview.subagentsRunning > 0 {
                    Text("서브에이전트 \(provider.overview.subagentsRunning)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if let message = provider.availability.message, provider.availability != .checking {
                    Text(message)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(nsColor: CharacterState.attentionYellow).opacity(0.9))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    AgentApp.activate(provider.kind)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(provider.name) 앱 열기")
            }

            if sessions.isEmpty {
                Text("열린 세션 없음")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.leading, 2)
            } else {
                ForEach(sessions.prefix(Self.maxRows)) { session in
                    SessionRow(session: session, kind: provider.kind,
                               needsApproval: session.isBusy && provider.displayState == .waitingForApproval,
                               detail: Self.detail(for: session, provider: provider))
                }
                if sessions.count > Self.maxRows {
                    Text("외 \(sessions.count - Self.maxRows)개")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.leading, 2)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentOverview.Session
    let kind: ProviderKind
    let needsApproval: Bool
    /// What the busy session is doing right now, when it is known.
    let detail: String?

    private var folder: URL? { session.directory.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(needsApproval ? Color(nsColor: CharacterState.attentionYellow)
                      : session.isBusy ? kind.accent : Color.white.opacity(0.22))
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.system(size: 11.5, weight: session.isBusy ? .medium : .regular))
                .foregroundStyle(.white.opacity(session.isBusy ? 0.92 : 0.6))
                .lineLimit(1)
            if needsApproval {
                Text("승인 대기")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: CharacterState.attentionYellow)))
                    .fixedSize()
            } else if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let folder {
                Text(folder.lastPathComponent)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(ShortTime.ago(session.updatedAt))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.3))
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(.white.opacity(needsApproval ? 0.1 : session.isBusy ? 0.06 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { if let folder { NSWorkspace.shared.open(folder) } }
        .contextMenu {
            if let folder {
                Button("폴더 열기") { NSWorkspace.shared.open(folder) }
                Button("터미널에서 열기") { LauncherService.openTerminal(at: folder) }
            }
            Button("\(kind.displayName) 앱 열기") { AgentApp.activate(kind) }
        }
        .help(session.directory ?? session.title)
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

// MARK: - 실행

/// The sites and folders worth one click, and the page each project is served at.
/// Two narrow columns, so the whole list is on screen without scrolling.
private struct LauncherPane: View {
    let launcher: LauncherService

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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
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
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
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

private struct LauncherMenu: View {
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
