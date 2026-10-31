import AppKit
import SwiftUI

/// The 결재함 inside the Jarvis area (2026-11-01, 동근님: 「노치에서 확인하고 승인할 수 있게」):
/// the waiting items, one item's details — for a code change the files, tests and diff, for a mail
/// draft who it is to and what it says — and 「반려」 / 「승인」, each asking for a second, confirming
/// tap. After a decision it shows what the server reported, nothing assumed.
struct JarvisApprovalsView: View {
    @Bindable var approvals: JarvisApprovals
    var onFocusChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topBar
            if let problem = approvals.problem {
                Text(problem)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchPalette.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let item = approvals.selected {
                ApprovalDetail(item: item, approvals: approvals, onFocusChange: onFocusChange)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button {
                approvals.selected == nil ? approvals.close() : approvals.back()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    Text(approvals.selected == nil ? "대화로" : "결재함")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(approvals.selected == nil ? "결재함 · 기다리는 \(approvals.items.count)건" : "")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: CharacterState.attentionYellow))
            Spacer(minLength: 0)
            if approvals.isLoading { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder
    private var list: some View {
        if approvals.items.isEmpty, !approvals.isLoading {
            Text("기다리는 결재가 없습니다")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(approvals.items) { item in
                        Button {
                            Task { await approvals.show(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.kind == "mail_draft" ? "envelope" : "chevron.left.forwardslash.chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: CharacterState.attentionYellow))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(1)
                                    if let summary = item.summary {
                                        Text(summary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if let created = item.createdAt {
                                    Text(ShortTime.ago(created))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// One item: what it is, what to judge, and the decision.
private struct ApprovalDetail: View {
    let item: JarvisApproval
    @Bindable var approvals: JarvisApprovals
    let onFocusChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 7) {
                    heading
                    if !item.isPending { result }   // what happened comes first, above what was judged
                    if let mail = item.mail { MailContent(mail: mail) }
                    if let code = item.code { CodeContent(code: code) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.isPending { decision }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                tag(item.kindWord, color: .white.opacity(0.7))
                tag(item.statusWord, color: statusColor)
                if let created = item.createdAt {
                    Text(ShortTime.ago(created))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Text(item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            if let summary = item.summary {
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "pending": Color(nsColor: CharacterState.attentionYellow)
        case "applied", "approved": Color(nsColor: CharacterState.doneGreen)
        case "failed": Color(nsColor: CharacterState.errorRed)
        default: .white.opacity(0.6)
        }
    }

    /// What the server reported after the decision.
    private var result: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("결과 · \(item.statusWord)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
            ForEach(Array(item.outcome.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(item.didFail ? 0.85 : 0.7))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = item.note, !note.isEmpty {
                Text("메모: \(note)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(statusColor.opacity(0.1)))
    }

    // MARK: Decision

    @ViewBuilder
    private var decision: some View {
        switch approvals.step {
        case .reading:
            VStack(alignment: .leading, spacing: 5) {
                JarvisInputField(text: $approvals.note, placeholder: "메모 (선택)", isEnabled: true,
                                 onSubmit: { _ in }, onFocusChange: onFocusChange)
                    .frame(height: 22)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    pill("반려", fill: .white.opacity(0.1)) { approvals.ask(.reject) }
                    pill("승인", fill: Color(nsColor: CharacterState.doneGreen).opacity(0.75)) { approvals.ask(.approve) }
                }
            }
        case .confirming(let decision):
            // The confirming button is NOT where 「승인」 was (that spot is 「취소」): one click must not
            // ask and confirm at once (the same trap as Send/Stop, 2026-11-01).
            VStack(alignment: .leading, spacing: 5) {
                Text(decision == .approve ? item.approveConsequence : "반려로 기록합니다. 되돌릴 수 없습니다.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    pill(decision == .approve ? "승인 확정" : "반려 확정",
                         fill: decision == .approve ? Color(nsColor: CharacterState.doneGreen).opacity(0.85)
                                                    : NotchPalette.red.opacity(0.8)) { approvals.confirm() }
                    Spacer(minLength: 0)
                    pill("취소", fill: .white.opacity(0.1)) { approvals.cancel() }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
        case .sending(let decision):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(decision == .approve ? "승인 보내는 중… (코드라면 합치는 중)" : "반려 보내는 중…")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func pill(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 26)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }
}

/// A mail draft: who, what, where it is saved. Nothing is sent from the notch.
private struct MailContent: View {
    let mail: JarvisApproval.MailDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field("받는 사람", mail.to.isEmpty ? "(기존 초안의 받는 사람)" : mail.to.joined(separator: ", "))
            if !mail.cc.isEmpty { field("참조", mail.cc.joined(separator: ", ")) }
            field("제목", mail.subject ?? "(제목 없음)")
            if let preview = mail.preview {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25)))
            }
            if let location = mail.location { field("저장 위치", location) }
            if let url = mail.viewURL {
                Button("Gmail에서 초안 보기 ↗") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(JarvisOrbView.blue)
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A code change: where, which files, the tests the team ran, what it says, and the diff.
private struct CodeContent: View {
    let code: JarvisApproval.CodeChange
    @State private var showsWholeDiff = false
    @State private var showsWholeSummary = false

    static let diffLines = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([code.repoName, code.branch.map { "브랜치 \($0)" }, code.baseBranch.map { "→ \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .textSelection(.enabled)
            tests
            if !code.files.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(code.files, id: \.self) { file in
                        Text(file.replacingOccurrences(of: "\t", with: "  "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            if let summary = code.teamSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(showsWholeSummary ? nil : 5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if summary.split(separator: "\n").count > 5 || summary.count > 300 {
                    more(showsWholeSummary ? "접기" : "팀 보고 더 보기") { showsWholeSummary.toggle() }
                }
            }
            diff
        }
    }

    @ViewBuilder
    private var tests: some View {
        if code.tests.isEmpty {
            Text("테스트 실행 기록 없음")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color(nsColor: CharacterState.attentionYellow))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(code.tests.enumerated()), id: \.offset) { _, run in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(Color(nsColor: run.ok ? CharacterState.doneGreen : CharacterState.errorRed))
                        Text(run.command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    .font(.system(size: 10))
                    .help(run.output ?? "")
                }
            }
        }
    }

    @ViewBuilder
    private var diff: some View {
        if let diff = code.diff, !diff.isEmpty {
            let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let shown = showsWholeDiff ? lines : Array(lines.prefix(Self.diffLines))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Self.color(of: line))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.3)))
            if lines.count > Self.diffLines {
                more(showsWholeDiff ? "접기" : "더 보기 (\(lines.count - Self.diffLines)줄 더)") { showsWholeDiff.toggle() }
            }
            if code.diffTruncated {
                Text("변경이 너무 길어 서버가 앞부분만 보냈습니다 — 전체는 앱에서")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        } else if let stat = code.diffstat {
            Text(stat)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    static func color(of line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return .white.opacity(0.45)
        }
        if line.hasPrefix("+") { return Color(nsColor: CharacterState.doneGreen) }
        if line.hasPrefix("-") { return Color(nsColor: CharacterState.errorRed) }
        if line.hasPrefix("@@") { return JarvisOrbView.blue }
        return .white.opacity(0.75)
    }

    private func more(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(JarvisOrbView.blue)
    }
}
