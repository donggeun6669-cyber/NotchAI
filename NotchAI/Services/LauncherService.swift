import AppKit
import Observation

/// One-click openers for the places the user goes back to every day: project folders, the
/// schedule board, GitHub pages, terminals. The list lives in an editable JSON file; the first
/// run writes one built from DEAN's project links.
@MainActor
@Observable
final class LauncherService {
    /// A single button. `value` is a URL, a path, or a path with the `term:` prefix
    /// (open a Terminal there).
    struct Target: Codable, Equatable, Identifiable {
        var label: String
        var symbol: String?
        var value: String

        var id: String { label + "\u{1}" + value }
        var isTerminal: Bool { value.hasPrefix(Self.terminalPrefix) }
        static let terminalPrefix = "term:"

        var url: URL? {
            var path = value
            if path.hasPrefix(Self.terminalPrefix) { path.removeFirst(Self.terminalPrefix.count) }
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        var icon: String {
            if let symbol { return symbol }
            if isTerminal { return "terminal" }
            if value.hasPrefix("http") { return "safari" }
            return value.hasSuffix("/") || !value.contains(".") ? "folder" : "doc.text"
        }
    }

    struct Item: Codable, Equatable, Identifiable {
        var name: String
        var targets: [Target]
        var id: String { name }
    }

    nonisolated static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchAI/launcher.json")
    nonisolated static let deanURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/DEAN")

    private(set) var items: [Item] = []

    init(load: Bool = true) {
        guard load else { return }
        if let items = Self.read() {
            self.items = items
        } else {
            rebuild()
        }
    }

    /// Re-reads the file; used after the user edits it.
    func reload() { items = Self.read() ?? items }

    /// Throws the file away and writes a fresh one from what is on disk now.
    func rebuild() {
        items = Self.discover()
        write()
    }

    func openFile() {
        write(ifMissing: true)
        NSWorkspace.shared.open(Self.fileURL)
    }

    func open(_ target: Target) {
        guard let url = target.url else { return }
        if target.isTerminal { Self.openTerminal(at: url) } else { NSWorkspace.shared.open(url) }
    }

    /// A Terminal window in `url`. Used by the launcher and by the repository list.
    static func openTerminal(at url: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func write(ifMissing: Bool = false) {
        if ifMissing && FileManager.default.fileExists(atPath: Self.fileURL.path) { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(items).write(to: Self.fileURL)
    }

    nonisolated private static func read() -> [Item]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([Item].self, from: data)
    }

    // MARK: Building the default list

    /// The places 동근님 goes back to, from what DEAN records: the university, the department,
    /// the academic calendar, the deployment dashboard, and the tools the notes keep pointing at.
    nonisolated static let sites: [Item] = [
        Item(name: "킹고포털", targets: [Target(label: "portal.skku.edu", symbol: "person.crop.square",
                                            value: "https://portal.skku.edu")]),
        Item(name: "아이캠퍼스", targets: [Target(label: "icampus.skku.edu", symbol: "book",
                                             value: "https://icampus.skku.edu")]),
        Item(name: "학교 공지", targets: [Target(label: "skku.edu", symbol: "megaphone",
                                            value: "https://www.skku.edu/skku/campus/skk_comm/notice01.do")]),
        Item(name: "학사일정", targets: [Target(label: "skku.edu", symbol: "calendar",
                                            value: "https://www.skku.edu/skku/edu/bachelor/ca_de_schedule.do")]),
        Item(name: "성균관대", targets: [Target(label: "skku.edu", symbol: "globe", value: "https://www.skku.edu")]),
        Item(name: "Vercel", targets: [Target(label: "배포 현황", symbol: "square.stack.3d.up",
                                              value: "https://vercel.com/dashboard")]),
        Item(name: "Google Drive", targets: [Target(label: "drive.google.com", symbol: "externaldrive",
                                                    value: "https://drive.google.com")]),
    ]

    /// DEAN, then the sites, then one address per project — the page that project actually serves.
    nonisolated static func discover() -> [Item] {
        var items: [Item] = []

        var deanTargets = [Target(label: "폴더", symbol: "folder", value: deanURL.path)]
        let board = deanURL.appendingPathComponent("01_ASSISTANT/2026-2_학기_상황판.html")
        if FileManager.default.fileExists(atPath: board.path) {
            deanTargets.append(Target(label: "상황판", symbol: "calendar", value: board.path))
        }
        items.append(Item(name: "DEAN", targets: deanTargets))
        items += sites

        for link in projectCodeLinks() {
            let project = link.deletingLastPathComponent()
            guard let address = mainURL(ofProjectAt: project), let host = URL(string: address)?.host else { continue }
            items.append(Item(name: shortProjectName(ofCodeLink: link),
                              targets: [Target(label: host, symbol: "globe", value: address)]))
        }
        return items
    }

    /// Words that mark the line where a project writes down the address it is served at.
    nonisolated static let deploymentWords = ["배포", "라이브", "운영", "주소", "deploy", "live"]
    /// Addresses that are never a project's own page.
    nonisolated static let notAProjectSite = ["github.com", "vercel.com", "figma.com", "claude.ai",
                                              "chatgpt.com", "notion.com", "notion.so", "localhost",
                                              "npmjs.com", "docs.google.com", "drive.google.com"]

    /// The page a project serves, as its own notes record it. Newest note wins; a project whose
    /// notes never mention an address has none.
    nonisolated static func mainURL(ofProjectAt project: URL) -> String? {
        let fm = FileManager.default
        var files = ((try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [])
        files += (try? fm.contentsOfDirectory(at: project.appendingPathComponent("logs"),
                                              includingPropertiesForKeys: nil)) ?? []
        let notes = files.filter { $0.pathExtension == "md" }
            .sorted { JSONLFollower.modificationDate($0) > JSONLFollower.modificationDate($1) }
            .prefix(12)
        for note in notes {
            guard let text = try? String(contentsOf: note, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let address = deploymentURL(inLine: String(line)) else { continue }
                return address
            }
        }
        return nil
    }

    /// The address on a line that says it is where the project is deployed.
    nonisolated static func deploymentURL(inLine line: String) -> String? {
        let lowercased = line.lowercased()
        guard deploymentWords.contains(where: lowercased.contains),
              let start = line.range(of: "https://") ?? line.range(of: "http://") else { return nil }
        let rest = line[start.lowerBound...]
        let address = String(rest.prefix { !" \t`\"'()<>*,".contains($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".·—-"))
        guard let host = URL(string: address)?.host,
              !notAProjectSite.contains(where: host.contains) else { return nil }
        return address
    }


    /// "QM" alone says nothing: a project one level down is named after its group too.
    nonisolated static func projectName(ofCodeLink link: URL) -> String {
        let project = link.deletingLastPathComponent()
        let group = project.deletingLastPathComponent().lastPathComponent
        // "03_PROJECTS" and a course year ("2026-2") are filing, not names.
        if group == "03_PROJECTS" || group == "02_STUDY"
            || group.range(of: #"^\d{4}-\d$"#, options: .regularExpression) != nil {
            return project.lastPathComponent
        }
        return group + " · " + project.lastPathComponent
    }

    /// In a list of addresses, the group is the name 동근님 uses ("JeparkENG", not "homepage").
    nonisolated static func shortProjectName(ofCodeLink link: URL) -> String {
        let full = projectName(ofCodeLink: link)
        return full.components(separatedBy: " · ").first ?? full
    }

    /// `code` symlinks under the project and course folders (they sit one to three deep).
    nonisolated static func projectCodeLinks() -> [URL] {
        ["03_PROJECTS", "02_STUDY"].flatMap { codeLinks(under: deanURL.appendingPathComponent($0)) }
    }

    nonisolated static func codeLinks(under root: URL) -> [URL] {
        let fm = FileManager.default
        func children(of url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var links: [URL] = []
        // A course year ("02_STUDY/2026-2") is one more level than a project group.
        func walk(_ folder: URL, depth: Int) {
            let link = folder.appendingPathComponent("code")
            if fm.fileExists(atPath: link.path) {
                links.append(link)
                return
            }
            guard depth > 0 else { return }
            for child in children(of: folder) { walk(child, depth: depth - 1) }
        }
        for child in children(of: root) { walk(child, depth: 2) }
        return links
    }
}
