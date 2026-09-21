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

    /// DEAN first, then one row per project that has a `code` link.
    nonisolated static func discover() -> [Item] {
        var items: [Item] = []

        var deanTargets = [Target(label: "폴더", symbol: "folder", value: deanURL.path)]
        let board = deanURL.appendingPathComponent("01_ASSISTANT/2026-2_학기_상황판.html")
        if FileManager.default.fileExists(atPath: board.path) {
            deanTargets.append(Target(label: "상황판", symbol: "calendar", value: board.path))
        }
        deanTargets.append(Target(label: "터미널", symbol: "terminal", value: Target.terminalPrefix + deanURL.path))
        items.append(Item(name: "DEAN", targets: deanTargets))

        for link in projectCodeLinks() {
            let folder = link.resolvingSymlinksInPath()
            let name = projectName(ofCodeLink: link)
            var targets = [Target(label: "코드", symbol: "folder", value: folder.path),
                           Target(label: "터미널", symbol: "terminal", value: Target.terminalPrefix + folder.path)]
            if let remote = githubURL(ofRepositoryAt: folder) {
                targets.append(Target(label: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", value: remote))
            }
            items.append(Item(name: name, targets: targets))
        }
        return items
    }

    /// "QM" alone says nothing: a project one level down is named after its group too.
    nonisolated static func projectName(ofCodeLink link: URL) -> String {
        let project = link.deletingLastPathComponent()
        let parent = project.deletingLastPathComponent()
        return parent.lastPathComponent == "03_PROJECTS"
            ? project.lastPathComponent
            : parent.lastPathComponent + " · " + project.lastPathComponent
    }

    /// `03_PROJECTS/**/code` symlinks (projects sit one or two folders deep).
    nonisolated static func projectCodeLinks() -> [URL] {
        let fm = FileManager.default
        let root = deanURL.appendingPathComponent("03_PROJECTS")
        func children(of url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var links: [URL] = []
        for project in children(of: root) {
            let link = project.appendingPathComponent("code")
            if fm.fileExists(atPath: link.path) {
                links.append(link)
                continue
            }
            for sub in children(of: project) {
                let inner = sub.appendingPathComponent("code")
                if fm.fileExists(atPath: inner.path) { links.append(inner) }
            }
        }
        return links
    }

    /// The origin remote from `.git/config`, as a web address.
    nonisolated static func githubURL(ofRepositoryAt folder: URL) -> String? {
        guard let config = try? String(contentsOf: folder.appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url = ") else { continue }
            return webURL(fromRemote: String(trimmed.dropFirst("url = ".count)))
        }
        return nil
    }

    /// "git@github.com:owner/repo.git" and "https://github.com/owner/repo.git" → the page.
    nonisolated static func webURL(fromRemote remote: String) -> String? {
        var text = remote
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasPrefix("git@") {
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let host = text[text.index(text.startIndex, offsetBy: 4)..<colon]
            return "https://\(host)/\(text[text.index(after: colon)...])"
        }
        return text.hasPrefix("http") ? text : nil
    }
}
