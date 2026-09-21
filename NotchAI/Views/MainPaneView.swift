import AppKit
import SwiftUI

/// The middle of the expanded notch: what the agents are doing (활동), what is left unsaved in
/// the repositories (작업물), what happened while the user was away (기록), and one-click
/// openers (실행). The notch conversation is still here, but only as a tab.
struct MainPaneView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case activity = "활동"
        case work = "작업물"
        case log = "기록"
        case launcher = "실행"
        case chat = "대화"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .activity: "bolt.horizontal.circle"
            case .work: "arrow.triangle.branch"
            case .log: "clock.arrow.circlepath"
            case .launcher: "square.grid.2x2"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
    }

    @Bindable var app: AppModel
    let notch: NotchViewModel

    var body: some View {
        VStack(spacing: 6) {
            header
            Group {
                switch app.mainTab {
                case .activity: ActivityPane(app: app)
                case .work: WorkPane(git: app.git)
                case .log: LogPane(log: app.activityLog)
                case .launcher: LauncherPane(launcher: app.launcher)
                case .chat: ChatView(provider: app.selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.15), value: app.mainTab)
    }

    /// The conversation tab only appears once there is a conversation to look at.
    private var tabs: [Tab] {
        let visible = Tab.allCases.filter { $0 != .chat }
        let hasChat = !app.selected.chat.messages.isEmpty || app.selected.isRunningCommand
        return hasChat ? visible + [.chat] : visible
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, isSelected: app.mainTab == tab, badge: badge(for: tab)) {
                    app.mainTab = tab
                }
            }
            Spacer(minLength: 4)
            trailingControls
        }
    }

    /// Small counts on the tabs, so the pane does not have to be open to see there is something.
    private func badge(for tab: Tab) -> Int? {
        switch tab {
        case .activity:
            let running = app.providers.reduce(0) { $0 + $1.overview.runningCount }
            return running > 0 ? running : nil
        case .work:
            let pending = app.git.pending.count
            return pending > 0 ? pending : nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch app.mainTab {
        case .work:
            RefreshButton(isRefreshing: app.git.isRefreshing) { app.git.refresh() }
        case .log where !app.activityLog.entries.isEmpty:
            SmallTextButton(title: "지우기") { app.activityLog.clear() }
        case .launcher:
            Menu {
                Button("목록 편집 (launcher.json)") { app.launcher.openFile() }
                Button("파일 다시 읽기") { app.launcher.reload() }
                Divider()
                Button("프로젝트에서 다시 만들기") { app.launcher.rebuild() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        case .chat:
            FolderButton(provider: app.selected)
            SmallTextButton(title: "새 대화") { app.selected.newChat() }
        default:
            EmptyView()
        }
        MoreMenu(app: app)
    }
}

private struct TabButton: View {
    let tab: MainPaneView.Tab
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(tab.rawValue)
                    .font(.system(size: 10.5, weight: .medium))
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(.white.opacity(0.75)))
                }
            }
            .foregroundStyle(isSelected ? .white.opacity(0.95) : .white.opacity(0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(isSelected ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 활동

/// One row per open session of both agents, busy ones first.
private struct ActivityPane: View {
    let app: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(app.providers, id: \.kind) { provider in
                    ProviderSection(provider: provider)
                }
            }
            .padding(.vertical, 2)
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
            } else if let detail, session.isBusy {
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

// MARK: - 작업물

/// Repositories with changes that are not committed, or commits that are not pushed.
private struct WorkPane: View {
    let git: GitStatusService

    var body: some View {
        let pending = git.pending
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                if pending.isEmpty {
                    Text(git.lastRefresh == nil ? "저장소를 읽는 중…" : "커밋·푸시 안 된 작업이 없습니다")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 4)
                }
                ForEach(pending) { repo in
                    RepoRow(repo: repo)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct RepoRow: View {
    let repo: GitStatusService.Repo

    private var folder: URL { URL(fileURLWithPath: repo.path) }

    var body: some View {
        HStack(spacing: 7) {
            Text(repo.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Text(repo.branch)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(0.07)))
                .fixedSize()
            if repo.changed > 0 {
                Chip(text: "변경 \(repo.changed)", color: Color(nsColor: CharacterState.attentionYellow))
            }
            if repo.untracked > 0 {
                Chip(text: "새 파일 \(repo.untracked)", color: .white.opacity(0.55))
            }
            if repo.ahead > 0 {
                Chip(text: "안 올림 \(repo.ahead)", color: Color(nsColor: CharacterState.doneGreen))
            }
            if !repo.hasUpstream {
                Chip(text: "원격 없음", color: Color(nsColor: CharacterState.errorRed))
            }
            Spacer(minLength: 4)
            if let last = repo.lastCommit {
                Text(ShortTime.ago(last))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(folder) }
        .contextMenu {
            Button("폴더 열기") { NSWorkspace.shared.open(folder) }
            Button("터미널에서 열기") { LauncherService.openTerminal(at: folder) }
            if let remote = LauncherService.githubURL(ofRepositoryAt: folder), let url = URL(string: remote) {
                Button("GitHub 열기") { NSWorkspace.shared.open(url) }
            }
        }
        .help(repo.path)
    }
}

private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .fixedSize()
    }
}

// MARK: - 기록

/// Finished, failed and approval-waiting moments, newest first.
private struct LogPane: View {
    let log: ActivityLogService

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                if log.entries.isEmpty {
                    Text("에이전트가 끝내거나 멈춘 일이 여기에 쌓입니다")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 4)
                }
                ForEach(log.entries) { entry in
                    HStack(spacing: 7) {
                        Image(systemName: entry.outcome.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(color(entry.outcome))
                            .frame(width: 12)
                        Text(entry.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let kind = entry.kind {
                            Text(kind.displayName)
                                .font(.system(size: 9))
                                .foregroundStyle(kind.accent.opacity(0.8))
                                .fixedSize()
                        }
                        Text(ShortTime.ago(entry.date))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.3))
                            .fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
                    .help(entry.date.formatted(date: .abbreviated, time: .standard))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func color(_ outcome: ActivityLogService.Outcome) -> Color {
        switch outcome {
        case .completed: Color(nsColor: CharacterState.doneGreen)
        case .failed: Color(nsColor: CharacterState.errorRed)
        case .approval: Color(nsColor: CharacterState.attentionYellow)
        }
    }
}

// MARK: - 실행

/// Folders, the schedule board, GitHub pages — one click each.
private struct LauncherPane: View {
    let launcher: LauncherService

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                if launcher.items.isEmpty {
                    Text("열 것이 없습니다 — 오른쪽 메뉴에서 목록을 만들 수 있습니다")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 4)
                }
                ForEach(launcher.items) { item in
                    HStack(spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .frame(width: 152, alignment: .leading)
                        ForEach(item.targets) { target in
                            Button {
                                launcher.open(target)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: target.icon)
                                        .font(.system(size: 9))
                                    Text(target.label)
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.white.opacity(0.08)))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(target.value)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Shared bits

private struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isRefreshing ? 0.2 : 0.5))
                .rotationEffect(.degrees(isRefreshing ? 180 : 0))
                .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                           value: isRefreshing)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help("저장소 상태 다시 읽기")
    }
}

private struct SmallTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
