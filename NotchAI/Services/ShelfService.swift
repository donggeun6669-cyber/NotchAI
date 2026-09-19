import AppKit
import Observation
import UniformTypeIdentifiers

/// A place to park files: drop them on the notch, drag them out somewhere else later.
/// The files stay where they are — only their locations are remembered.
@MainActor
@Observable
final class ShelfService {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var name: String { url.lastPathComponent }
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    static let limit = 12
    private static let storageKey = "shelfPaths"

    private(set) var items: [Item] = []
    /// Tests use a shelf that does not touch the saved list.
    private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
        guard persists else { return }
        let paths = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        items = paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { Item(url: URL(fileURLWithPath: $0)) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.insert(Item(url: url), at: 0)
        }
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func revealInFinder(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Drops that no longer exist (moved or deleted elsewhere) are cleaned up.
    func prune() {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard existing.count != items.count else { return }
        items = existing
        save()
    }

    private func save() {
        guard persists else { return }
        UserDefaults.standard.set(items.map(\.url.path), forKey: Self.storageKey)
    }
}
