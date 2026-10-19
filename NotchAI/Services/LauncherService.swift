import AppKit
import Observation

/// One-click openers for the places the user goes back to every day: folders, files, sites,
/// terminals. The list lives in a JSON file; the first run writes the app's default list
/// (`defaultItems()`: DEAN's links in NotchAI, nothing in NotchDesk). Places are added and removed
/// from the notch itself, or by editing the file.
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

    nonisolated static let fileURL = AppPaths.support.appendingPathComponent("launcher.json")

    private(set) var items: [Item] = []
    /// Where the list is kept; nil keeps it in memory only (tests).
    private let storeURL: URL?

    init(load: Bool = true, storeURL: URL? = LauncherService.fileURL) {
        self.storeURL = storeURL
        guard load else { return }
        if let items = read() {
            self.items = items
        } else {
            rebuild()
        }
    }

    /// Re-reads the file; used after the user edits it.
    func reload() { items = read() ?? items }

    /// Throws the file away and writes the app's default list again.
    func rebuild() {
        items = Self.defaultItems()
        write()
    }

    // MARK: Adding and removing

    /// Folders and files (or apps), one button each, named after themselves. Ones already on the
    /// list are skipped.
    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !contains(path) else { continue }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let isApp = url.pathExtension == "app"
            let name = isApp || !isFolder ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            items.append(Item(name: name, targets: [
                Target(label: isApp ? "앱" : isFolder ? "폴더" : "파일",
                       symbol: isApp ? "app" : isFolder ? "folder" : "doc", value: path)]))
        }
        write()
    }

    /// A site; "naver.com" becomes "https://naver.com". Returns false when it is not an address.
    @discardableResult
    func addWebsite(name: String, address: String) -> Bool {
        guard let value = Self.webAddress(address) else { return false }
        guard !contains(value) else { return true }
        let host = URL(string: value)?.host ?? value
        let title = name.trimmingCharacters(in: .whitespaces)
        items.append(Item(name: title.isEmpty ? host : title,
                          targets: [Target(label: host, symbol: "globe", value: value)]))
        write()
        return true
    }

    /// Takes one button off the list (an item with no buttons left goes too).
    func remove(_ target: Target) {
        for index in items.indices {
            items[index].targets.removeAll { $0 == target }
        }
        items.removeAll { $0.targets.isEmpty }
        write()
    }

    private func contains(_ value: String) -> Bool {
        items.contains { $0.targets.contains { $0.value == value } }
    }

    /// "naver.com" → "https://naver.com"; nil for something that cannot be a web address.
    nonisolated static func webAddress(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard let host = URL(string: value)?.host, host.contains(".") || host == "localhost" else { return nil }
        return value
    }

    func openFile() {
        guard let storeURL else { return }
        write(ifMissing: true)
        NSWorkspace.shared.open(storeURL)
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
        guard let storeURL else { return }
        if ifMissing && FileManager.default.fileExists(atPath: storeURL.path) { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(items).write(to: storeURL)
    }

    private func read() -> [Item]? {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode([Item].self, from: data)
    }
}
