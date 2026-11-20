import Foundation

/// Summary returned by the same private widget endpoint used by the phone.
struct JarvisWorkroomWidget: Decodable, Equatable {
    struct Handoff: Decodable, Equatable { let project: String?; let status: String? }
    var handoff: Handoff? = nil
    let active: Int
    let review: Int
    let done: Int
    let workroomURL: String

    enum CodingKeys: String, CodingKey {
        case active, review, done, handoff
        case workroomURL = "workroom_url"
    }

    static func parse(_ data: Data) -> Self? {
        guard let widget = try? JSONDecoder().decode(Self.self, from: data),
              min(widget.active, widget.review, widget.done) >= 0 else { return nil }
        return widget
    }

    /// Carry over only the task ID. A server response cannot choose an external browser target.
    func destination(base: URL) -> URL? {
        let home = base.appending(path: "workspace/workroom", directoryHint: .notDirectory)
        guard var safe = URLComponents(url: home, resolvingAgainstBaseURL: true),
              let targetURL = URL(string: workroomURL, relativeTo: base)?.absoluteURL,
              let target = URLComponents(url: targetURL, resolvingAgainstBaseURL: true),
              let scheme = safe.scheme?.lowercased(), ["http", "https"].contains(scheme),
              target.scheme?.lowercased() == scheme, target.host?.lowercased() == safe.host?.lowercased(),
              (target.port ?? (scheme == "https" ? 443 : 80)) == (safe.port ?? (scheme == "https" ? 443 : 80)),
              target.user == nil, target.password == nil, target.fragment == nil,
              safe.user == nil, safe.password == nil, target.percentEncodedPath == safe.percentEncodedPath else {
            return nil
        }
        let query = target.queryItems ?? []
        if !query.isEmpty {
            guard query.count == 1, query[0].name == "task", let id = query[0].value,
                  id.hasPrefix("chat-"), id.count == 41,
                  UUID(uuidString: String(id.dropFirst(5))) != nil else { return nil }
        }
        safe.queryItems = query.isEmpty ? nil : query
        safe.fragment = nil
        return safe.url
    }
}
