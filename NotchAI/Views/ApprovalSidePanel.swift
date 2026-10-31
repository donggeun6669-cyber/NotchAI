import AppKit
import SwiftUI

/// Colours and type for 동근님's own screens (2026-11-01, Jarvis DECISIONS 「색은 배경화면, 글씨는
/// Pretendard, 구성은 토스처럼」): the light grey studio, the black slab and the red ribbon of his
/// wallpaper. Red is only for the one primary button on a card and the waiting dot — never for errors.
enum StudioTheme {
    struct Palette {
        var background: Color
        var card: Color
        var text: Color
        var secondary: Color
        var muted: Color
        var greyButton: Color
        var greyButtonText: Color
    }

    static let red = Color(hex: 0xE53D40)
    static let redPressed = Color(hex: 0xAE1F23)
    static let snackbar = Color(hex: 0x27282A)
    static let undo = Color(hex: 0xFF8A8C)
    static let success = Color(hex: 0x2E9E5B)
    static let nsRed = NSColor(srgbRed: 0xE5 / 255, green: 0x3D / 255, blue: 0x40 / 255, alpha: 1)

    static func palette(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(background: Color(hex: 0x1C1D1F), card: Color(hex: 0x27282A), text: Color(hex: 0xF2F3F5),
                      secondary: Color(hex: 0xA9ACB2), muted: Color(hex: 0x8A8D93),
                      greyButton: Color(hex: 0x34363A), greyButtonText: Color(hex: 0xD5D7DB))
            : Palette(background: Color(hex: 0xF2F3F5), card: .white, text: Color(hex: 0x27282A),
                      secondary: Color(hex: 0x4E5056), muted: Color(hex: 0x6B6E75),
                      greyButton: Color(hex: 0xF2F3F5), greyButtonText: Color(hex: 0x4E5056))
    }

    /// Pretendard (installed in ~/Library/Fonts); the system font where it is missing.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .bold, .heavy, .black: "Pretendard-Bold"
        case .semibold: "Pretendard-SemiBold"
        case .medium: "Pretendard-Medium"
        default: "Pretendard-Regular"
        }
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight)
    }

    static func nsFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Pretendard-Regular", size: size) ?? .systemFont(ofSize: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The 결재 panel beside the open notch (2026-11-01 5차, 동근님: 「지금은 결재 승인까지 가는데 화면이
/// 바뀌고, 눌러야 하는 버튼이 많아서 불편」). One card per waiting item, everything to judge on the
/// card, and the decision on it: press and hold to approve code, one tap to confirm a mail draft,
/// one tap to reject with five seconds to undo.
struct ApprovalSidePanel: View {
    @Bindable var approvals: JarvisApprovals
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Cards that start with their changed lines open (pictures of the panel).
    var openDiffs: Set<String> = []

    @Environment(\.colorScheme) private var scheme
    private var palette: StudioTheme.Palette { StudioTheme.palette(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(approvals.cards) { item in
                        ApprovalCard(item: item, approvals: approvals, palette: palette, onFocusChange: onFocusChange,
                                     showsDiff: openDiffs.contains(item.id))
                    }
                    if let problem = approvals.problem {
                        Text(problem)
                            .font(StudioTheme.font(12, .medium))
                            .foregroundStyle(palette.muted)
                    }
                }
                .padding(.bottom, 2)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CardsHeight.self, value: proxy.size.height)
                })
            }
            .frame(maxHeight: .infinity)
            if let reject = approvals.pendingRejects.last {
                UndoBar(reject: reject) { approvals.undoReject(reject.id) }
            } else if let notice = approvals.rejectNotice {
                Text(notice)
                    .font(StudioTheme.font(12.5, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioTheme.snackbar))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(palette.background))
        .onPreferenceChange(CardsHeight.self) { cards in
            // Header, spacing, the snackbar's room and padding around the cards.
            approvals.contentHeight = cards + 18 * 2 + 28 + 14 + 58
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(approvals.waitingCount > 0 ? "결재 \(approvals.waitingCount)건" : "결재")
                .font(StudioTheme.font(22, .bold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            Button { approvals.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(palette.greyButton))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("닫기 — 새 결재가 오면 다시 열려요")
        }
    }
}

private struct CardsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One item: who raised it, what it is, what the button will do, the evidence, and the decision.
private struct ApprovalCard: View {
    let item: JarvisApproval
    @Bindable var approvals: JarvisApprovals
    let palette: StudioTheme.Palette
    let onFocusChange: (Bool) -> Void

    @State var showsDiff = false
    @State private var writesNote = false

    private var result: JarvisApproval? { approvals.results[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text([item.teamWord, item.kindWord].compactMap { $0 }.joined(separator: " · "))
                .font(StudioTheme.font(12, .medium))
                .foregroundStyle(palette.muted)
            Text(item.title)
                .font(StudioTheme.font(16, .bold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let result {
                outcome(result)
            } else {
                Text(item.consequence)
                    .font(StudioTheme.font(13, .medium))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                evidence
                if let problem = approvals.problems[item.id] { trouble(problem) }
                actions
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.card))
    }

    // MARK: Evidence

    @ViewBuilder
    private var evidence: some View {
        if let evidence = item.evidence {
            Text(evidence)
                .font(StudioTheme.font(12.5))
                .foregroundStyle(palette.muted)
        }
        if let mail = item.mail, let preview = mail.preview {
            Text(preview)
                .font(StudioTheme.font(12.5))
                .foregroundStyle(palette.secondary)
                .lineLimit(showsDiff ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let url = mail.viewURL {
                link("Gmail에서 초안 보기 ›") { NSWorkspace.shared.open(url) }
            }
        }
        if item.code != nil {
            link(showsDiff ? "바뀐 줄 접기" : "바뀐 줄 보기 ›") {
                showsDiff.toggle()
                if showsDiff { Task { await approvals.loadDetail(item.id) } }
            }
            if showsDiff {
                if let code = approvals.details[item.id]?.code {
                    DiffView(code: code)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: Decision

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if writesNote {
                JarvisInputField(text: Binding(get: { approvals.notes[item.id] ?? "" },
                                               set: { approvals.notes[item.id] = $0 }),
                                 placeholder: "메모 (결정과 함께 남아요)", isEnabled: true,
                                 onSubmit: { _ in }, onFocusChange: onFocusChange,
                                 textColor: NSColor(palette.text), placeholderColor: NSColor(palette.muted),
                                 font: StudioTheme.nsFont(13))
                    .frame(height: 22)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.greyButton))
            } else {
                link("메모") { writesNote = true }
            }
            if approvals.deciding.contains(item.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(item.needsHold ? "합치는 중이에요" : "기록하는 중이에요")
                        .font(StudioTheme.font(13, .medium))
                        .foregroundStyle(palette.secondary)
                }
                .frame(height: 40)
            } else {
                // 1 : 1.6 — the quiet choice on the left, the one red button on the right.
                GeometryReader { proxy in
                    let unit = (proxy.size.width - 8) / 2.6
                    HStack(spacing: 8) {
                        Button { approvals.reject(item.id) } label: {
                            Text(item.kind == "mail_draft" ? "문제 있음" : "반려")
                                .font(StudioTheme.font(14, .semibold))
                                .foregroundStyle(palette.greyButtonText)
                                .frame(width: unit, height: 40)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.greyButton))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        if item.needsHold {
                            HoldToConfirm(title: "꾹 눌러 승인") { Task { await approvals.approve(item.id) } }
                                .frame(width: unit * 1.6)
                        } else {
                            Button { Task { await approvals.approve(item.id) } } label: {
                                Text("확인")
                                    .font(StudioTheme.font(14, .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: unit * 1.6, height: 40)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioTheme.red))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .help("확인함으로 기록해요. 메일은 보내지 않아요")
                        }
                    }
                }
                .frame(height: 40)
            }
        }
    }

    /// What the server said happened. Never assumed.
    private func outcome(_ result: JarvisApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.didFail ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.didFail ? palette.secondary : StudioTheme.success)
                Text(result.statusWord)
                    .font(StudioTheme.font(14, .bold))
                    .foregroundStyle(palette.text)
            }
            ForEach(Array(result.outcome.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(StudioTheme.font(12.5))
                    .foregroundStyle(palette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = approvals.problems[item.id] { trouble(problem) }
            link("닫기") { approvals.closeResult(item.id) }
        }
    }

    /// Trouble talking to the server: plain, not red (red is the primary button's).
    private func trouble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(StudioTheme.font(12.5, .semibold))
        .foregroundStyle(palette.secondary)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StudioTheme.font(12.5, .semibold))
                .foregroundStyle(palette.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The red button that approves only when held down: the deeper red fills from the left over
/// `duration`; letting go early fills back and nothing happens.
struct HoldToConfirm: View {
    let title: String
    var duration: Double = 0.7
    let action: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                StudioTheme.red
                StudioTheme.redPressed.frame(width: proxy.size.width * progress)
                Text(title)
                    .font(StudioTheme.font(14, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            action()
        } onPressingChanged: { pressing in
            if pressing {
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.18)) { progress = 0 }
            }
        }
        .help("0.7초 동안 누르고 있으면 승인돼요. 중간에 떼면 취소")
        .accessibilityAddTraits(.isButton)
    }
}

/// 「반려했어요 · 되돌리기 5」: the 반려 is sent when the count reaches 0.
private struct UndoBar: View {
    let reject: JarvisApprovals.PendingReject
    let undo: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = max(0, Int(reject.deadline.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 8) {
                Text("반려했어요")
                    .font(StudioTheme.font(13, .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button(action: undo) {
                    Text("되돌리기 \(left)")
                        .font(StudioTheme.font(13, .bold))
                        .foregroundStyle(StudioTheme.undo)
                        .monospacedDigit()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioTheme.snackbar))
        }
    }
}

/// The changed lines, inline in the card: green for added, grey for removed (red belongs to the
/// primary button), blue for where. 40 lines first, then 더 보기.
private struct DiffView: View {
    let code: JarvisApproval.CodeChange
    @State private var showsAll = false
    @Environment(\.colorScheme) private var scheme
    static let firstLines = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !code.tests.isEmpty {
                ForEach(Array(code.tests.enumerated()), id: \.offset) { _, run in
                    Label(run.command, systemImage: run.ok ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(run.ok ? StudioTheme.success : Color(hex: 0x6B6E75))
                        .lineLimit(1)
                        .help(run.output ?? "")
                }
            }
            if let diff = code.diff, !diff.isEmpty {
                let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((showsAll ? lines : Array(lines.prefix(Self.firstLines))).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Self.color(of: line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The black slab of the wallpaper; a shade deeper than a dark card so it still stands out.
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: scheme == .dark ? 0x141517 : 0x27282A)))
                if lines.count > Self.firstLines {
                    Button(showsAll ? "접기" : "더 보기 (\(lines.count - Self.firstLines)줄)") { showsAll.toggle() }
                        .buttonStyle(.plain)
                        .font(StudioTheme.font(12, .semibold))
                        .foregroundStyle(Color(hex: 0x6B6E75))
                }
                if code.diffTruncated {
                    Text("너무 길어 앞부분만 왔어요 — 전체는 앱에서")
                        .font(StudioTheme.font(11.5))
                        .foregroundStyle(Color(hex: 0x6B6E75))
                }
            } else if let stat = code.diffstat {
                Text(stat).font(.system(size: 10.5, design: .monospaced))
            }
        }
    }

    static func color(of line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return Color(hex: 0x8A8D93)
        }
        if line.hasPrefix("+") { return Color(hex: 0x6FD08F) }
        if line.hasPrefix("-") { return Color(hex: 0x9EA1A7) }
        if line.hasPrefix("@@") { return Color(hex: 0x7FB6FF) }
        return Color(hex: 0xE4E5E8)
    }
}
