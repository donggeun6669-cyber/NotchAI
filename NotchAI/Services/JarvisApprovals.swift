import Foundation
import Observation

// Jarvis's 결재함 in the notch (2026-11-01): what is waiting for 동근님's yes, what it would do, and
// approve / reject — through the desktop's `/approvals` endpoints (jarvis/api.py, approvals.py).
// The notch shows only what the server says happened after a decision, never an assumed success.

/// One item in the 결재함.
struct JarvisApproval: Identifiable, Equatable {
    struct MailDraft: Equatable {
        var to: [String]
        var cc: [String]
        var subject: String?
        var preview: String?
        var location: String?
        var viewURL: URL?
    }

    struct TestRun: Equatable {
        var command: String
        var ok: Bool
        var output: String?
    }

    struct CodeChange: Equatable {
        var repo: String?
        var branch: String?
        var baseBranch: String?
        var files: [String]
        var diffstat: String?
        /// Only in the detail (`GET /approvals/{id}`); the list leaves it out.
        var diff: String?
        var diffTruncated: Bool
        var tests: [TestRun]
        var teamSummary: String?
        var remote: String?

        var repoName: String? { repo.map { ($0 as NSString).lastPathComponent } }
    }

    var id: String
    var kind: String
    /// Which team raised it ("dev", "secretary", …).
    var team: String?
    var status: String
    var statusWord: String
    var title: String
    var summary: String?
    var createdAt: Date?
    var note: String?
    /// What the server reports happened when it was decided, line by line.
    var outcome: [String]
    var mail: MailDraft?
    var code: CodeChange?

    var isPending: Bool { status == "pending" }
    /// Approved, but it could not be applied (merge conflict, the branch moved, …).
    var didFail: Bool { status == "failed" }

    var kindWord: String {
        switch kind {
        case "mail_draft": "메일 초안"
        case "code_change": "코드 변경"
        default: kind
        }
    }

    /// The short kind for the pill beside the notch.
    var shortKind: String {
        switch kind {
        case "mail_draft": "메일"
        case "code_change": "코드"
        default: kind
        }
    }

    var teamWord: String? {
        switch team {
        case "dev"?: "개발팀"
        case "secretary"?: "비서실"
        case let other?: other
        case nil: nil
        }
    }

    /// What the primary button will do, said on the card before it is pressed.
    var consequence: String {
        switch kind {
        case "mail_draft":
            let to = mail.map { $0.to.isEmpty ? "기존 받는 사람" : $0.to.joined(separator: ", ") } ?? "받는 사람 미상"
            return "받는 사람 \(to) · 보내기는 Gmail에서 직접"
        case "code_change":
            let name = code?.repoName ?? "저장소"
            let base = code?.baseBranch ?? "기본 브랜치"
            let push = code?.remote.map { "\($0)에 push" } ?? "push 안 함"
            return "\(name) \(base)에 합쳐요 · \(push)"
        default:
            return "데스크탑 Jarvis가 처리해요"
        }
    }

    /// Files and tests in one line, for a code change.
    var evidence: String? {
        guard let code else { return nil }
        let files = "파일 \(code.files.count)개"
        guard !code.tests.isEmpty else { return files + " · 테스트 기록 없음" }
        let failed = code.tests.filter { !$0.ok }.count
        return files + (failed == 0 ? " · 테스트 \(code.tests.count)번 모두 통과" : " · 테스트 \(failed)번 실패")
    }

    /// Code is merged on approval, so it takes a press-and-hold; a mail draft is only marked as seen.
    var needsHold: Bool { kind != "mail_draft" }

    static func parse(_ object: [String: Any]) -> JarvisApproval? {
        guard let id = object["id"] as? String else { return nil }
        let kind = object["kind"] as? String ?? ""
        let status = object["status"] as? String ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        var item = JarvisApproval(
            id: id, kind: kind, team: object["team"] as? String, status: status,
            statusWord: object["status_ko"] as? String ?? status,
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
            summary: object["summary"] as? String,
            createdAt: JarvisPresence.date(object["created_at"]),
            note: object["note"] as? String,
            outcome: (object["outcome"] as? [String: Any]).map(Self.outcomeLines) ?? [])
        switch kind {
        case "mail_draft":
            item.mail = MailDraft(to: strings(payload["to"]), cc: strings(payload["cc"]),
                                  subject: payload["subject"] as? String, preview: payload["preview"] as? String,
                                  location: payload["location"] as? String,
                                  viewURL: (payload["view_url"] as? String).flatMap(URL.init(string:)))
        case "code_change":
            let tests = (payload["tests"] as? [[String: Any]] ?? []).map {
                TestRun(command: $0["command"] as? String ?? "", ok: $0["ok"] as? Bool ?? false,
                        output: $0["output_tail"] as? String)
            }
            item.code = CodeChange(repo: payload["repo"] as? String, branch: payload["branch"] as? String,
                                   baseBranch: payload["base_branch"] as? String, files: strings(payload["files"]),
                                   diffstat: payload["diffstat"] as? String, diff: payload["diff"] as? String,
                                   diffTruncated: payload["diff_truncated"] as? Bool ?? false, tests: tests,
                                   teamSummary: payload["summary"] as? String, remote: payload["remote"] as? String)
        default:
            break
        }
        return item
    }

    static func parse(list data: Data) -> [JarvisApproval]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.compactMap(parse)
    }

    static func parse(item data: Data) -> JarvisApproval? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(parse)
    }

    /// The server's outcome as sentences: its message, how it merged, the push, any error.
    static func outcomeLines(_ outcome: [String: Any]) -> [String] {
        var lines: [String] = []
        if let message = outcome["message"] as? String { lines.append(message) }
        if outcome["merged"] as? Bool == true {
            let method = (outcome["method"] as? String).map { " (\($0))" } ?? ""
            lines.append("합쳤습니다\(method)")
        }
        if let push = outcome["push"] as? String { lines.append(push) }
        if let note = outcome["note"] as? String { lines.append(note) }
        if let error = outcome["error"] as? String { lines.append(error) }
        return lines
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? (value as? String).map { [$0] } ?? []
    }
}

/// The 결재함 beside the open notch (2026-11-01 5차): the waiting items as cards, decisions in as few
/// taps as possible, and only what the server answered afterwards.
///
/// Approving code is a press-and-hold on the card (the view); confirming a mail draft is one tap.
/// 반려 hides the card at once and is sent only after `undoDelay` unless 되돌리기 is pressed — if the
/// app quits first nothing was sent and the item simply stays pending.
@MainActor
@Observable
final class JarvisApprovals {
    struct PendingReject: Identifiable, Equatable {
        var id: String
        var title: String
        var deadline: Date
        var note: String?
    }

    /// Shown beside the closed notch for a while when a new item arrives.
    struct Pill: Equatable {
        var count: Int
        var kind: String
    }

    /// Waiting items as last read (without diffs).
    private(set) var items: [JarvisApproval] = []
    /// Items read in full (with the diff), for 「바뀐 줄 보기」.
    private(set) var details: [String: JarvisApproval] = [:]
    /// Decided items as the server answered, shown on their card until closed.
    private(set) var results: [String: JarvisApproval] = [:]
    /// A card's own trouble (the server refused, or did not answer).
    private(set) var problems: [String: String] = [:]
    private(set) var deciding: Set<String> = []
    private(set) var pendingRejects: [PendingReject] = []
    /// What the server said about the last sent 반려, for a moment.
    private(set) var rejectNotice: String?
    private(set) var pill: Pill?
    /// The list could not be read.
    private(set) var problem: String?
    var notes: [String: String] = [:]
    /// Cards with their changed lines open, and with the note field open.
    var openDiffs: Set<String> = []
    var openNotes: Set<String> = []
    @ObservationIgnored var undoDelay: Duration = .seconds(5)
    @ObservationIgnored var pillDuration: Duration = .seconds(10)

    @ObservationIgnored private let jarvis: JarvisService
    @ObservationIgnored private var knownIDs: Set<String>?
    @ObservationIgnored private var pillTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(jarvis: JarvisService) {
        self.jarvis = jarvis
    }

    // MARK: What the panel shows

    /// Cards in order: decided ones (their result) first, then the waiting ones not being rejected.
    var cards: [JarvisApproval] {
        let rejecting = Set(pendingRejects.map(\.id))
        let decided = results.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return decided + items.filter { !rejecting.contains($0.id) && results[$0.id] == nil }
    }

    var waitingCount: Int { items.filter { results[$0.id] == nil }.count - pendingRejects.count }

    /// The panel beside the open notch should be up. Only after 「보기」 (6차, 동근님 「보기를 눌러야
    /// 옆 패널에 뜨는걸로」) — the notch opening never brings it up by itself; waiting items are
    /// said by the red dot and the pill. Never with nothing in it.
    var wantsPanel: Bool {
        guard isOpen else { return false }
        return !cards.isEmpty || !pendingRejects.isEmpty || rejectNotice != nil
    }

    /// 「보기」 was pressed and the panel has not been closed since.
    private(set) var isOpen = false

    /// 「보기」 on the yellow line or the pill.
    func open() {
        isOpen = true
        hidePill()
        Task { await refresh() }
    }

    /// ✕, or the notch closing: the panel goes until 「보기」 again. Results already read go with it;
    /// a 반려 still counting down is sent (or undone) all the same.
    func dismiss() {
        isOpen = false
        results.removeAll()
        problems.removeAll()
    }

    /// A decided card's 「닫기」.
    func closeResult(_ id: String) {
        results[id] = nil
        problems[id] = nil
    }

    // MARK: Reading

    /// Presence reported a different number waiting: read the list, and announce what is new.
    func countChanged(to count: Int) {
        Task { await refresh(announcing: true) }
    }

    func refresh(announcing: Bool = false) async {
        guard let url = url("/approvals?status=pending") else { return }
        guard case .success((let data, 200)) = await get(url), let list = JarvisApproval.parse(list: data) else {
            problem = "결재함을 읽지 못했어요"
            return
        }
        problem = nil
        items = list
        let ids = Set(list.map(\.id))
        if announcing, let known = knownIDs, let first = list.first(where: { !known.contains($0.id) }) {
            showPill(Pill(count: list.count, kind: first.shortKind))
        }
        knownIDs = (knownIDs ?? []).union(ids)
    }

    /// 「바뀐 줄 보기」: opens the lines in the card, reading them the first time.
    func toggleDiff(_ id: String) {
        if openDiffs.remove(id) == nil {
            openDiffs.insert(id)
            Task { await loadDetail(id) }
        }
    }

    /// The full item, for its diff.
    func loadDetail(_ id: String) async {
        guard details[id] == nil, let url = url("/approvals/\(id)") else { return }
        if case .success((let data, 200)) = await get(url), let item = JarvisApproval.parse(item: data) {
            details[id] = item
        }
    }

    private func showPill(_ pill: Pill) {
        self.pill = pill
        pillTask?.cancel()
        let duration = pillDuration
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.pill = nil
        }
    }

    func hidePill() {
        pillTask?.cancel()
        pill = nil
    }

    // MARK: Deciding

    /// 승인 (code, after the hold) or 확인 (mail, one tap). Shows what the server answered.
    func approve(_ id: String) async {
        guard !deciding.contains(id) else { return }
        await post(.approve, id: id, note: note(for: id))
    }

    /// 반려 / 문제 있음: the card goes at once; the request waits out `undoDelay`.
    func reject(_ id: String, now: Date = .now) {
        guard let item = items.first(where: { $0.id == id }), !pendingRejects.contains(where: { $0.id == id }) else { return }
        let entry = PendingReject(id: id, title: item.title, deadline: now.addingTimeInterval(Self.seconds(undoDelay)),
                                  note: note(for: id))
        pendingRejects.append(entry)
        let delay = undoDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.pendingRejects.contains(where: { $0.id == id }) else { return }   // undone
            self.pendingRejects.removeAll { $0.id == id }
            await self.post(.reject, id: id, note: entry.note)
        }
    }

    /// 되돌리기: nothing is sent and the card comes back.
    func undoReject(_ id: String) {
        pendingRejects.removeAll { $0.id == id }
    }

    private enum Decision: String { case approve, reject }

    private func post(_ decision: Decision, id: String, note: String?) async {
        guard let url = url("/approvals/\(id)/\(decision.rawValue)") else { return }
        deciding.insert(id)
        problems[id] = nil
        defer { deciding.remove(id) }
        let json = try? JSONSerialization.data(withJSONObject: note.map { ["note": $0] } ?? [:])
        do {
            let (data, status) = try await jarvis.transport.send("POST", url, json: json)
            if status == 200, let item = JarvisApproval.parse(item: data) {
                settle(item, after: decision)
            } else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                problems[id] = detail ?? "처리하지 못했어요 (\(status))"
                await reread(id)
            }
        } catch {
            // It may or may not have arrived: say so, and show the item as the server has it now.
            problems[id] = "결과를 받지 못했어요 — 서버에서 다시 읽은 상태예요"
            await reread(id)
        }
        notes[id] = nil
        jarvis.askNow()   // the count beside the notch
        await refresh()
    }

    /// A decision the server confirmed: an approval keeps its card with the result; a 반려 is said
    /// in the snackbar.
    private func settle(_ item: JarvisApproval, after decision: Decision) {
        if decision == .reject, item.status == "rejected" {
            say("반려됐어요" + (item.outcome.first.map { " · " + $0 } ?? ""))
        } else {
            results[item.id] = item
        }
    }

    /// After a refusal or no answer: the item as it really is now.
    private func reread(_ id: String) async {
        guard let url = url("/approvals/\(id)") else { return }
        guard case .success((let data, 200)) = await get(url), let item = JarvisApproval.parse(item: data) else { return }
        if !item.isPending { results[id] = item }   // already decided (here or elsewhere): show how
    }

    private func say(_ notice: String) {
        rejectNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.rejectNotice = nil
        }
    }

    private func note(for id: String) -> String? {
        let text = (notes[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: Network

    private func get(_ url: URL) async -> Result<(Data, Int), JarvisOffline> {
        do { return .success(try await jarvis.transport.get(url)) } catch { return .failure(JarvisOffline(error: error)) }
    }

    private func url(_ path: String) -> URL? {
        jarvis.baseURL.flatMap { URL(string: $0.absoluteString + path) }
    }
}
