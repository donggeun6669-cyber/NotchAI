import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The lower half of the expanded notch: what is playing, recent clipboard entries, and a shelf
/// for files. One tab at a time so the panel stays small.
struct DeskView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case music = "Music"
        case clips = "Clips"
        case shelf = "Shelf"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .music: "music.note"
            case .clips: "doc.on.clipboard"
            case .shelf: "tray.full"
            }
        }
    }

    @Bindable var desk: DeskModel
    let accent: Color

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
                case .music: MusicPane(music: desk.music, accent: accent)
                case .clips: ClipsPane(clipboard: desk.clipboard)
                case .shelf: ShelfPane(shelf: desk.shelf, accent: accent)
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
                Image(systemName: track.isPlaying ? "waveform" : "pause.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text("\(track.artist) · \(track.source.rawValue)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if track.source.controllable {
                    HStack(spacing: 10) {
                        control("backward.fill") { music.previous() }
                        control(track.isPlaying ? "pause.fill" : "play.fill") { music.playPause() }
                        control("forward.fill") { music.next() }
                    }
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

    var body: some View {
        if clipboard.entries.isEmpty {
            Text("복사한 내용이 여기에 쌓입니다 (앱을 끄면 사라짐)")
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
                }
            }
        }
    }
}

private struct ShelfPane: View {
    let shelf: ShelfService
    let accent: Color

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
