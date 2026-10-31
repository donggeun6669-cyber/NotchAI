import AppKit
import Foundation
import Observation

// Jarvis, the assistant on the always-on desktop (2026-11-01). Its job server is reachable only
// inside the user's Tailscale network; the notch asks it what it is doing every few seconds and
// shows only what it answers. Nothing here sends work to Jarvis: talking happens in its own app.

/// What Jarvis says it is doing (`/presence` → `state`).
enum JarvisState: Equatable {
    case idle
    case thinking
    case working
    case needsApproval
    /// Voice: Jarvis is hearing the user / talking back (arrives with the voice step).
    case listening
    case speaking
    /// A state this build does not know yet. Shown as such, never guessed.
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "idle": self = .idle
        case "thinking": self = .thinking
        case "working": self = .working
        case "needs_approval": self = .needsApproval
        case "listening": self = .listening
        case "speaking": self = .speaking
        default: self = .unknown(raw)
        }
    }

    var word: String {
        switch self {
        case .idle: "쉬는 중"
        case .thinking: "생각 중"
        case .working: "작업 중"
        case .needsApproval: "승인 대기"
        case .listening: "듣는 중"
        case .speaking: "말하는 중"
        case .unknown(let raw): "알 수 없는 상태 (\(raw))"
        }
    }
}

/// One answer from the server: `/presence`, or the same shape worked out from `/health` on a
/// server that does not have `/presence` yet.
struct JarvisPresence: Equatable {
    var state: JarvisState
    var runningJobs: Int
    var queuedJobs: Int
    var approvals: Int
    var activeConversations: Int
    var lastEventAt: Date?
    var version: String?
    /// Worked out from `/health` job counts, because the server answered 404 to `/presence`.
    var isDerived = false

    /// Something waiting for the user's yes outranks whatever else is going on.
    var shownState: JarvisState { approvals > 0 ? .needsApproval : state }

    /// `/presence`. Missing counts are 0; a missing or unreadable state makes the answer bad.
    static func parse(presence data: Data) -> JarvisPresence? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String else { return nil }
        return JarvisPresence(state: JarvisState(raw: state),
                              runningJobs: int(object["running_jobs"]),
                              queuedJobs: int(object["queued_jobs"]),
                              approvals: int(object["approvals"]),
                              activeConversations: int(object["active_conversations"]),
                              lastEventAt: date(object["last_event_at"]),
                              version: object["version"] as? String)
    }

    /// `/health` → `jobs.running` / `jobs.queued`. A running job is work; a queued one is about to
    /// start (the server only queues while its slots are full or for the moment before pickup),
    /// so it reads as thinking rather than resting.
    static func parse(health data: Data) -> JarvisPresence? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = object["jobs"] as? [String: Any] else { return nil }
        let running = int(jobs["running"])
        let queued = int(jobs["queued"])
        return JarvisPresence(state: running > 0 ? .working : queued > 0 ? .thinking : .idle,
                              runningJobs: running, queuedJobs: queued, approvals: 0,
                              activeConversations: 0, lastEventAt: nil,
                              version: object["version"] as? String, isDerived: true)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// The server writes Unix seconds.
    static func date(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// A job from `/jobs`: what it is called and how it stands.
struct JarvisJob: Equatable, Identifiable {
    var id: String
    var title: String
    var status: String
    var createdAt: Date?

    /// Korean for the server's job statuses; an unknown one is shown as it came.
    var statusWord: String { Self.word(for: status) }

    static func word(for status: String) -> String {
        switch status {
        case "queued": "대기"
        case "running": "진행 중"
        case "done": "완료"
        case "failed": "실패"
        case "cancelled": "취소"
        case "interrupted": "중단"
        default: status
        }
    }

    static func parse(list data: Data) -> [JarvisJob]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return JarvisJob(id: id, title: title, status: object["status"] as? String ?? "",
                             createdAt: JarvisPresence.date(object["created_at"]))
        }
    }
}

/// Why the notch cannot see Jarvis. Each is a different thing to check.
enum JarvisOffline: Error, Equatable {
    /// The name does not resolve: Tailscale is off on this Mac (or the address is wrong).
    case nameNotFound
    /// No answer in time: the desktop is off, asleep, or off the network.
    case unreachable
    /// The desktop answered but the Jarvis service behind it did not (Tailscale Serve says 502).
    case serviceDown(Int)
    /// Something answered, but not in Jarvis's shape.
    case badAnswer

    init(error: Error) {
        switch (error as? URLError)?.code {
        case .cannotFindHost?, .dnsLookupFailed?: self = .nameNotFound
        default: self = .unreachable
        }
    }

    init(status: Int) {
        self = (500...599).contains(status) ? .serviceDown(status) : .badAnswer
    }

    var explanation: String {
        switch self {
        case .nameNotFound: "주소를 찾지 못했습니다 — 이 맥의 Tailscale이 켜져 있는지 확인하세요"
        case .unreachable: "데스크탑이 응답하지 않습니다 — 꺼졌거나 네트워크에서 빠졌을 수 있습니다"
        case .serviceDown(let status): "데스크탑은 닿지만 Jarvis 서비스가 응답하지 않습니다 (\(status))"
        case .badAnswer: "Jarvis가 아닌 답이 왔습니다 — 주소를 확인하세요"
        }
    }
}

/// What the notch knows about Jarvis right now.
enum JarvisConnection: Equatable {
    /// No address set: Jarvis is not shown at all.
    case off
    /// Started, first answer not in yet.
    case checking
    case online(JarvisPresence)
    case offline(JarvisOffline)
}

/// How often to ask. Every few seconds while Jarvis answers; after misses, twice as long each
/// time up to a minute, so a desktop that is off is not hammered all night.
struct JarvisBackoff: Equatable {
    static let interval: Duration = .seconds(3)
    static let longest: Duration = .seconds(60)

    private(set) var failures = 0
    private(set) var hasAnswered = false

    mutating func succeeded() {
        failures = 0
        hasAnswered = true
    }

    mutating func failed() { failures += 1 }

    /// One miss right after good answers may be a blip on the network, so it takes two in a row.
    /// Before the first answer there is nothing true to keep showing, so one miss is enough.
    var isOffline: Bool { failures >= (hasAnswered ? 2 : 1) }

    var nextDelay: Duration {
        guard failures > 1 else { return Self.interval }
        let seconds = 3 * (1 << min(failures - 1, 5))   // 6, 12, 24, 48, then capped
        return min(.seconds(seconds), Self.longest)
    }
}

/// Where the notch finds Jarvis. Kept in this Mac's app defaults like the other `…` menu settings,
/// never in the source: the address names a private network, and the repository is public. Empty
/// (the default) means Jarvis is not shown.
enum JarvisSettings {
    static let key = "jarvisBaseURL"
    static let defaultAddress = ""
    /// What the address looks like, for the settings field.
    static let example = "https://<기기 이름>.<tailnet>.ts.net"

    static var address: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultAddress }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// "desk.example.ts.net/" → "https://desk.example.ts.net". Empty turns Jarvis off (nil).
    static func baseURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// How the notch talks to the server. A protocol so the tests can answer for it.
protocol JarvisTransport: Sendable {
    /// The body and HTTP status. Throws only when there was no HTTP answer at all.
    func get(_ url: URL) async throws -> (Data, Int)
    /// A request with an optional JSON body (the chat's POSTs).
    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int)
    /// A request whose answer is an event stream: the status, then the body line by line as it
    /// arrives (for a status other than 200, the whole body as one line).
    func lines(_ method: String, _ url: URL, json: Data?) async throws -> (Int, AsyncThrowingStream<String, Error>)
}

extension JarvisTransport {
    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int) {
        throw URLError(.unsupportedURL)
    }

    func lines(_ method: String, _ url: URL, json: Data?) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        throw URLError(.unsupportedURL)
    }
}

struct URLSessionJarvisTransport: JarvisTransport {
    /// Short: the server sits on the local tailnet and answers in milliseconds when it is there.
    static let timeout: TimeInterval = 4

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// A reply can take minutes when Jarvis uses tools; only a long silence between bytes ends it.
    private let streaming: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func request(_ method: String, _ url: URL, json: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ method: String, _ url: URL, json: Data?) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: Self.request(method, url, json: json))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func lines(_ method: String, _ url: URL, json: Data?) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await streaming.bytes(for: Self.request(method, url, json: json))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    if status == 200 {
                        for try await line in bytes.lines { continuation.yield(line) }
                    } else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        continuation.yield(String(decoding: body, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }
}

/// Push-to-talk, for when voice arrives (a later step). The section shows a talk button only when
/// `JarvisService.voice` is set; nothing records audio until then.
@MainActor
protocol JarvisVoiceControl: AnyObject {
    var isTalking: Bool { get }
    func startTalking()
    func stopTalking()
}

/// Polls Jarvis and keeps what the notch shows: the connection, its state, the latest jobs.
@MainActor
@Observable
final class JarvisService {
    static let jobLimit = 3
    /// The job list follows the state; without a change it is still refreshed this often.
    static let jobsInterval: TimeInterval = 30
    /// After a 404 on `/presence`, ask `/health` instead and look for `/presence` again this often
    /// (it is being added to the server).
    static let presenceRecheck: TimeInterval = 60

    private(set) var connection: JarvisConnection = .off
    private(set) var jobs: [JarvisJob] = []
    /// When the server last answered.
    private(set) var lastAnswer: Date?
    private(set) var backoff = JarvisBackoff()
    /// The push-to-talk hook. Nil until voice exists.
    var voice: (any JarvisVoiceControl)?
    /// Called when the number of waiting 결재 items changes (the 결재 panel reads the list then).
    @ObservationIgnored var onApprovalCount: ((Int) -> Void)?
    @ObservationIgnored private var lastApprovalCount: Int?

    /// The address as typed in the settings; "" turns Jarvis off.
    var address: String {
        didSet {
            guard address != oldValue else { return }
            if persists { JarvisSettings.address = address }
            reset()
            if isStarted { restart() }
        }
    }

    var baseURL: URL? { JarvisSettings.baseURL(address) }
    var isEnabled: Bool { baseURL != nil }

    /// The last good presence, kept through a single blip so the notch does not flicker.
    var presence: JarvisPresence? {
        if case .online(let presence) = connection { return presence }
        return nil
    }

    @ObservationIgnored let transport: any JarvisTransport
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var presenceMissingSince: Date?
    @ObservationIgnored private var lastJobsFetch: Date?
    @ObservationIgnored private var jobsWanted = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(transport: any JarvisTransport = URLSessionJarvisTransport(), address: String? = nil) {
        self.transport = transport
        self.persists = address == nil
        self.address = address ?? JarvisSettings.address
        connection = baseURL == nil ? .off : .checking
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Back from sleep or onto a network: ask now instead of waiting out a long back-off.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.askNow() }
        })
        restart()
    }

    /// Ask again right away, e.g. when the panel opens or after waking.
    func askNow() {
        jobsWanted = true
        backoff = JarvisBackoff(keepingAnswered: backoff)
        if isStarted { restart() }
    }

    /// The panel opened: the job list should be fresh.
    func wantJobs() {
        jobsWanted = true
        if isStarted, presence != nil {
            Task { await refreshJobs() }
        }
    }

    private func reset() {
        backoff = JarvisBackoff()
        presenceMissingSince = nil
        lastJobsFetch = nil
        jobsWanted = true
        jobs = []
        lastAnswer = nil
        connection = baseURL == nil ? .off : .checking
    }

    private func restart() {
        loop?.cancel()
        guard baseURL != nil else {
            connection = .off
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    // MARK: One round

    /// Asks once and returns how long to wait before the next round.
    @discardableResult
    func pollOnce(now: Date = .now) async -> Duration {
        guard let base = baseURL else {
            connection = .off
            return JarvisBackoff.longest
        }
        let before = presence
        switch await fetchPresence(base: base, now: now) {
        case .success(let presence):
            backoff.succeeded()
            lastAnswer = now
            connection = .online(presence)
            if presence.approvals != lastApprovalCount {
                lastApprovalCount = presence.approvals
                onApprovalCount?(presence.approvals)
            }
            if jobsDue(before: before, after: presence, now: now) { await refreshJobs(now: now) }
        case .failure(let reason):
            backoff.failed()
            if backoff.isOffline {
                connection = .offline(reason)
            }
        }
        return backoff.nextDelay
    }

    private func fetchPresence(base: URL, now: Date) async -> Result<JarvisPresence, JarvisOffline> {
        let missing = presenceMissingSince.map { now.timeIntervalSince($0) < Self.presenceRecheck } ?? false
        if !missing {
            let answer = await get(base, "/presence")
            switch answer {
            case .success((let data, 200)):
                presenceMissingSince = nil
                return JarvisPresence.parse(presence: data).map { .success($0) } ?? .failure(.badAnswer)
            case .success((_, 404)):
                presenceMissingSince = now
            case .success((_, let status)):
                return .failure(JarvisOffline(status: status))
            case .failure(let reason):
                return .failure(reason)
            }
        }
        switch await get(base, "/health") {
        case .success((let data, 200)):
            return JarvisPresence.parse(health: data).map { .success($0) } ?? .failure(.badAnswer)
        case .success((_, let status)):
            return .failure(JarvisOffline(status: status))
        case .failure(let reason):
            return .failure(reason)
        }
    }

    private func jobsDue(before: JarvisPresence?, after: JarvisPresence, now: Date) -> Bool {
        if jobsWanted { return true }
        guard let lastJobsFetch, now.timeIntervalSince(lastJobsFetch) < Self.jobsInterval else { return true }
        guard let before else { return true }
        return before.shownState != after.shownState || before.runningJobs != after.runningJobs
            || before.queuedJobs != after.queuedJobs || before.lastEventAt != after.lastEventAt
    }

    /// The latest few jobs. A failure here keeps the old list: the state above is what counts.
    func refreshJobs(now: Date = .now) async {
        guard let base = baseURL else { return }
        jobsWanted = false
        lastJobsFetch = now
        if case .success((let data, 200)) = await get(base, "/jobs?limit=\(Self.jobLimit)"),
           let list = JarvisJob.parse(list: data) {
            jobs = Array(list.prefix(Self.jobLimit))
        }
    }

    private func get(_ base: URL, _ path: String) async -> Result<(Data, Int), JarvisOffline> {
        guard let url = URL(string: base.absoluteString + path) else { return .failure(.badAnswer) }
        do {
            return .success(try await transport.get(url))
        } catch {
            return .failure(JarvisOffline(error: error))
        }
    }

    // MARK: Opening the app

    /// The chat app, or the job board on a server that does not have `/app` yet.
    static func chatURL(base: URL, appStatus: Int?) -> URL {
        let app = URL(string: base.absoluteString + "/app") ?? base
        return appStatus == 404 ? URL(string: base.absoluteString + "/") ?? base : app
    }

    /// Opens Jarvis in the browser. Asks `/app` first so a server without it opens the board instead.
    func openApp() {
        guard let base = baseURL else { return }
        Task {
            let status: Int?
            if case .success((_, let code)) = await get(base, "/app") { status = code } else { status = nil }
            NSWorkspace.shared.open(Self.chatURL(base: base, appStatus: status))
        }
    }
}

extension JarvisBackoff {
    /// A fresh count that remembers whether the server has ever answered.
    init(keepingAnswered other: JarvisBackoff) {
        self.init()
        hasAnswered = other.hasAnswered
    }
}
