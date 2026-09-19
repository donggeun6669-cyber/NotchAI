import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The lower half of the expanded notch: what is playing, recent clipboard entries, and a shelf
/// for files. One tab at a time so the panel stays small.
struct DeskView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case today = "Today"
        case music = "Music"
        case clips = "Clips"
        case shelf = "Shelf"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .today: "calendar"
            case .music: "music.note"
            case .clips: "doc.on.clipboard"
            case .shelf: "tray.full"
            }
        }
    }

    @Bindable var desk: DeskModel
    let accent: Color
    /// Puts text into the command field (clipboard entry, file path).
    let onInsert: (String) -> Void
    /// Sends text as a command straight away.
    let onSend: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        desk.tab = tab
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(desk.tab == tab ? .white.opacity(0.95) : .white.opacity(0.45))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(desk.tab == tab ? 0.12 : 0)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                trailingControl
            }

            Group {
                switch desk.tab {
                case .today: TodayPane(schedule: desk.schedule, accent: accent)
                case .music: MusicPane(music: desk.music, accent: accent)
                case .clips: ClipsPane(clipboard: desk.clipboard, onInsert: onInsert, onSend: onSend)
                case .shelf: ShelfPane(shelf: desk.shelf, accent: accent, onInsert: onInsert)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.18), value: desk.tab)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch desk.tab {
        case .clips where !desk.clipboard.entries.isEmpty:
            Button("Clear") { desk.clipboard.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        case .shelf where !desk.shelf.items.isEmpty:
            Text("드래그해서 꺼내기")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.3))
        default:
            EmptyView()
        }
    }
}

private struct MusicPane: View {
    let music: NowPlayingService
    let accent: Color

    var body: some View {
        if let track = music.track {
            HStack(spacing: 10) {
                if let data = track.artwork, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: track.isPlaying ? "waveform" : "pause.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(accent)
                        .frame(width: 20)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text([track.artist, track.label ?? track.source.rawValue]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if track.source.controllable || music.canUseMediaKeys {
                    HStack(spacing: 10) {
                        control("backward.fill") { music.previous() }
                        // A browser tab does not say whether it is paused, so show a toggle there.
                        control(!track.stateKnown ? "playpause.fill"
                                : track.isPlaying ? "pause.fill" : "play.fill") { music.playPause() }
                        control("forward.fill") { music.next() }
                    }
                } else {
                    Button("재생 버튼 켜기") { MediaKeys.askForPermission() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accent)
                        .help("손쉬운 사용 권한을 허용하면 유튜브 뮤직 등 브라우저 재생도 조작할 수 있습니다")
                }
            }
            .padding(.top, 2)
        } else if music.permissionDenied {
            HStack(spacing: 8) {
                Text("음악을 읽으려면 자동화 권한이 필요합니다")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: CharacterState.attentionYellow).opacity(0.9))
                Button("설정 열기") { AppleScript.openAutomationSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
            }
            .padding(.top, 6)
        } else {
            Text("재생 중인 음악 없음 — Music · Spotify · Chrome 탭을 읽습니다")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 6)
        }
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ClipsPane: View {
    let clipboard: ClipboardService
    let onInsert: (String) -> Void
    let onSend: (String) -> Void

    var body: some View {
        if clipboard.entries.isEmpty {
            Text("복사한 내용이 여기에 쌓입니다 (최근 12개)")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(clipboard.entries.prefix(3)) { entry in
                    Button {
                        clipboard.copy(entry)
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(entry.date, style: .relative)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.3))
                                .fixedSize()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("클릭하면 다시 복사됩니다")
                    .contextMenu {
                        Button("명령에 붙이기") { onInsert(entry.text) }
                        Button("그대로 보내기") { onSend(entry.text) }
                    }
                }
            }
        }
    }
}

private struct ShelfPane: View {
    let shelf: ShelfService
    let accent: Color
    let onInsert: (String) -> Void

    var body: some View {
        if shelf.items.isEmpty {
            Text("파일을 여기에 끌어다 놓으면 잠시 보관합니다")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelf.items) { item in
                        VStack(spacing: 3) {
                            Image(nsImage: item.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                            Text(item.name)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 62)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                        .onTapGesture { shelf.revealInFinder(item) }
                        .contextMenu {
                            Button("경로를 명령에 붙이기") { onInsert("\"\(item.url.path)\"") }
                            Button("Finder에서 보기") { shelf.revealInFinder(item) }
                            Button("치우기") { shelf.remove(item) }
                        }
                        .help(item.url.path)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

/// Next class and the nearest deadlines, from DEAN's schedule file.
private struct TodayPane: View {
    let schedule: ScheduleService
    let accent: Color

    var body: some View {
        if schedule.fileMissing {
            Text("일정 파일이 없습니다 — schedule-sync의 calendar_sync.py를 한 번 실행하세요")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap")
                        .font(.system(size: 9.5))
                        .foregroundStyle(accent)
                        .frame(width: 12)
                    if let next = schedule.nextClass {
                        Text(next.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(Self.when(next.start) + (next.room.isEmpty ? "" : " · \(next.room)"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        Text("앞으로 예정된 수업 없음")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                    if schedule.isStale {
                        Text("오래된 자료")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color(nsColor: CharacterState.attentionYellow).opacity(0.8))
                            .help("calendar_sync.py를 다시 실행하면 최신으로 바뀝니다")
                    }
                }

                ForEach(schedule.upcomingDeadlines()) { deadline in
                    let days = ScheduleService.daysLeft(deadline.date)
                    HStack(spacing: 6) {
                        Text("D\(days == 0 ? "-0" : "-\(days)")")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(days <= 1 ? Color(nsColor: CharacterState.errorRed) : accent)
                            .frame(width: 26, alignment: .leading)
                        Text(deadline.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(days <= 1 ? 0.95 : 0.7))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// "오늘 13:30", "내일 09:00" or "09-21 09:00".
    static func when(_ date: Date, now: Date = .now) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        switch ScheduleService.daysLeft(date, from: now) {
        case 0: return "오늘 \(time)"
        case 1: return "내일 \(time)"
        default: return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " " + time
        }
    }
}
