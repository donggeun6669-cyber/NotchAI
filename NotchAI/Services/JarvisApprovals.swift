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

    /// What 「승인」 will do, said before the confirming tap.
    var approveConsequence: String {
        switch kind {
        case "mail_draft":
            return "「확인함」으로 기록합니다. 메일은 보내지 않습니다 — 보내기는 Gmail에서 직접."
        case "code_change":
            let name = code?.repoName ?? "저장소"
            let base = code?.baseBranch ?? "기본 브랜치"
            let push = code?.remote == nil ? "원격 저장소가 없어 push는 하지 않습니다." : "합친 뒤 \(code?.remote ?? "") 로 push합니다."
            return "\(name)의 \(base)에 이 변경을 합칩니다. \(push)"
        default:
            return "데스크탑 Jarvis가 이 항목을 처리합니다."
        }
    }

    static func parse(_ object: [String: Any]) -> JarvisApproval? {
        guard let id = object["id"] as? String else { return nil }
        let kind = object["kind"] as? String ?? ""
        let status = object["status"] as? String ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        var item = JarvisApproval(
            id: id, kind: kind, status: status,
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

/// The 결재함 as the notch keeps it: the pending list, the item open in detail, and the result of
/// a decision as the server reported it.
@MainActor
@Observable
final class JarvisApprovals {
    enum Decision: String { case approve, reject }

    /// A decision that has been asked for and waits for the confirming tap.
    enum Step: Equatable {
        case reading
        case confirming(Decision)
        case sending(Decision)
    }

    /// The 결재함 is showing (instead of the conversation).
    var isOpen = false
    private(set) var items: [JarvisApproval] = []
    /// The item open in detail, as last read from the server.
    private(set) var selected: JarvisApproval?
    private(set) var step: Step = .reading
    private(set) var isLoading = false
    /// Something that went wrong talking to the server, or its refusal (already decided).
    private(set) var problem: String?
    var note = ""

    /// A confirming tap this soon after asking is the same click landing again.
    static let confirmGrace: TimeInterval = 0.6

    @ObservationIgnored private let jarvis: JarvisService
    @ObservationIgnored private var askedAt: Date?

    init(jarvis: JarvisService) {
        self.jarvis = jarvis
    }

    func open() {
        isOpen = true
        selected = nil
        step = .reading
        Task { await refresh() }
    }

    func close() {
        isOpen = false
        selected = nil
        step = .reading
        problem = nil
    }

    func refresh() async {
        guard let url = url("/approvals?status=pending") else { return }
        isLoading = true
        defer { isLoading = false }
        switch await get(url) {
        case .success((let data, 200)):
            if let list = JarvisApproval.parse(list: data) {
                items = list
                problem = nil
            } else {
                problem = "결재함 목록을 읽지 못했습니다"
            }
        case .success((_, let status)):
            problem = "결재함을 열지 못했습니다 (\(status))"
        case .failure(let reason):
            problem = reason.explanation
        }
    }

    /// Opens one item with everything the server has on it (the diff is only in the detail).
    func show(_ id: String) async {
        step = .reading
        note = ""
        problem = nil
        if let listed = items.first(where: { $0.id == id }) { selected = listed }
        await reload(id)
    }

    func back() {
        selected = nil
        step = .reading
        problem = nil
        Task { await refresh() }
    }

    private func reload(_ id: String) async {
        guard let url = url("/approvals/\(id)") else { return }
        isLoading = true
        defer { isLoading = false }
        switch await get(url) {
        case .success((let data, 200)):
            if let item = JarvisApproval.parse(item: data) { selected = item } else { problem = "항목을 읽지 못했습니다" }
        case .success((_, 404)):
            problem = "서버에 없는 항목입니다"
        case .success((_, let status)):
            problem = "항목을 열지 못했습니다 (\(status))"
        case .failure(let reason):
            problem = reason.explanation
        }
    }

    // MARK: Deciding

    /// The first tap: asks for a confirming one.
    func ask(_ decision: Decision, now: Date = .now) {
        guard selected?.isPending == true, step == .reading else { return }
        askedAt = now
        step = .confirming(decision)
    }

    func cancel() {
        if case .confirming = step { step = .reading }
    }

    /// The confirming tap. Sends the decision and shows what the server answered.
    func confirm(now: Date = .now) {
        guard case .confirming(let decision) = step, let item = selected else { return }
        if let askedAt, now.timeIntervalSince(askedAt) < Self.confirmGrace { return }
        step = .sending(decision)
        problem = nil
        let note = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await send(decision, item: item.id, note: note.isEmpty ? nil : note) }
    }

    func send(_ decision: Decision, item id: String, note: String?) async {
        defer { step = .reading }
        guard let url = url("/approvals/\(id)/\(decision.rawValue)") else { return }
        var body: [String: Any] = [:]
        if let note { body["note"] = note }
        let json = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, status) = try await jarvis.transport.send("POST", url, json: json)
            switch status {
            case 200:
                if let item = JarvisApproval.parse(item: data) {
                    selected = item
                } else {
                    problem = "서버 답을 읽지 못했습니다 — 다시 불러와 확인합니다"
                    await reload(id)
                }
            default:
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                problem = detail ?? "처리하지 못했습니다 (\(status))"
                await reload(id)   // show what the item really is now (e.g. already decided)
            }
        } catch {
            // The request may or may not have arrived: say so, and read the item's real state.
            problem = "결과를 받지 못했습니다 — 서버에서 다시 읽은 상태를 보여 드립니다 (\(JarvisOffline(error: error).explanation))"
            await reload(id)
        }
        items.removeAll { $0.id == id && selected?.isPending == false }
        jarvis.askNow()   // the 결재 count beside the notch
    }

    // MARK: Network

    private func get(_ url: URL) async -> Result<(Data, Int), JarvisOffline> {
        do { return .success(try await jarvis.transport.get(url)) } catch { return .failure(JarvisOffline(error: error)) }
    }

    private func url(_ path: String) -> URL? {
        jarvis.baseURL.flatMap { URL(string: $0.absoluteString + path) }
    }
}
