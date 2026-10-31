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
    /// The live panel scrolls when its cards are taller than the screen allows; the copy used to
    /// measure the panel's height does not (2026-11-01 6차: the panel was sized from a reading that
    /// never arrived and showed only its title).
    var scrolls = true

    static let width: CGFloat = 220

    @Environment(\.colorScheme) private var scheme
    private var palette: StudioTheme.Palette { StudioTheme.palette(scheme) }

    var body: some View {
        Group {
            if scrolls {
                ScrollView(showsIndicators: false) { content }
            } else {
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.background))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(approvals.cards) { item in
                ApprovalCard(item: item, approvals: approvals, palette: palette, onFocusChange: onFocusChange)
            }
            if let problem = approvals.problem {
                Text(problem)
                    .font(StudioTheme.font(11, .medium))
                    .foregroundStyle(palette.muted)
            }
            if let reject = approvals.pendingRejects.last {
                UndoBar(reject: reject) { approvals.undoReject(reject.id) }
            } else if let notice = approvals.rejectNotice {
                Text(notice)
                    .font(StudioTheme.font(11.5, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioTheme.snackbar))
            }
        }
        .padding(12)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(approvals.waitingCount > 0 ? "결재 \(approvals.waitingCount)건" : "결재")
                .font(StudioTheme.font(16, .bold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            Button { approvals.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.muted)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(palette.greyButton))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("닫기 — 새 결재가 오면 다시 열려요")
        }
        .padding(.horizontal, 2)
    }
}

/// One item: who raised it, what it is, what the button will do, the evidence, and the decision.
private struct ApprovalCard: View {
    let item: JarvisApproval
    @Bindable var approvals: JarvisApprovals
    let palette: StudioTheme.Palette
    let onFocusChange: (Bool) -> Void

    // Kept in the model so the measuring copy of the panel opens the same things.
    private var showsDiff: Bool { approvals.openDiffs.contains(item.id) }
    private var writesNote: Bool { approvals.openNotes.contains(item.id) }

    private var result: JarvisApproval? { approvals.results[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([item.teamWord, item.kindWord].compactMap { $0 }.joined(separator: " · "))
                .font(StudioTheme.font(10.5, .medium))
                .foregroundStyle(palette.muted)
            Text(item.title)
                .font(StudioTheme.font(13, .bold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let result {
                outcome(result)
            } else {
                Text(item.consequence)
                    .font(StudioTheme.font(11.5, .medium))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                evidence
                if let problem = approvals.problems[item.id] { trouble(problem) }
                actions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.card))
    }

    // MARK: Evidence

    @ViewBuilder
    private var evidence: some View {
        if let evidence = item.evidence {
            Text(evidence)
                .font(StudioTheme.font(11))
                .foregroundStyle(palette.muted)
        }
        if let mail = item.mail, let preview = mail.preview {
            Text(preview)
                .font(StudioTheme.font(11))
                .foregroundStyle(palette.secondary)
                .lineLimit(showsDiff ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let url = mail.viewURL {
                link("Gmail에서 초안 보기 ›") { NSWorkspace.shared.open(url) }
            }
        }
        if item.code != nil {
            link(showsDiff ? "바뀐 줄 접기" : "바뀐 줄 보기 ›") {
                approvals.toggleDiff(item.id)
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
                                 font: StudioTheme.nsFont(11.5))
                    .frame(height: 18)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.greyButton))
            } else {
                link("메모") { approvals.openNotes.insert(item.id) }
            }
            if approvals.deciding.contains(item.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(item.needsHold ? "합치는 중이에요" : "기록하는 중이에요")
                        .font(StudioTheme.font(11.5, .medium))
                        .foregroundStyle(palette.secondary)
                }
                .frame(height: 32)
            } else {
                // 1 : 1.6 — the quiet choice on the left, the one red button on the right.
                GeometryReader { proxy in
                    let unit = (proxy.size.width - 6) / 2.6
                    HStack(spacing: 6) {
                        Button { approvals.reject(item.id) } label: {
                            Text(item.kind == "mail_draft" ? "문제 있음" : "반려")
                                .font(StudioTheme.font(12, .semibold))
                                .foregroundStyle(palette.greyButtonText)
                                .lineLimit(1)
                                .frame(width: unit, height: 32)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.greyButton))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        if item.needsHold {
                            HoldToConfirm(title: "꾹 눌러 승인") { Task { await approvals.approve(item.id) } }
                                .frame(width: unit * 1.6)
                        } else {
                            Button { Task { await approvals.approve(item.id) } } label: {
                                Text("확인")
                                    .font(StudioTheme.font(12, .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: unit * 1.6, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioTheme.red))
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help("확인함으로 기록해요. 메일은 보내지 않아요")
                        }
                    }
                }
                .frame(height: 32)
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
                    .font(StudioTheme.font(12.5, .bold))
                    .foregroundStyle(palette.text)
            }
            ForEach(Array(result.outcome.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(StudioTheme.font(11))
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
        .font(StudioTheme.font(11, .semibold))
        .foregroundStyle(palette.secondary)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StudioTheme.font(11, .semibold))
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
                    .font(StudioTheme.font(12, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10))
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
                    .font(StudioTheme.font(11.5, .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button(action: undo) {
                    Text("되돌리기 \(left)")
                        .font(StudioTheme.font(11.5, .bold))
                        .foregroundStyle(StudioTheme.undo)
                        .monospacedDigit()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioTheme.snackbar))
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
                        .font(.system(size: 9.5, design: .monospaced))
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
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Self.color(of: line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
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
                Text(stat).font(.system(size: 9.5, design: .monospaced))
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
