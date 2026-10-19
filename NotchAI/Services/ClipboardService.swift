import AppKit
import Observation

/// Recent clipboard entries, capped. Kept in a file only this user can read
/// (`~/Library/Application Support/NotchAI/clipboard.json`) so they survive restarts.
/// Items marked as concealed by password managers are never recorded.
@MainActor
@Observable
final class ClipboardService {
    struct Entry: Identifiable, Equatable, Codable {
        var id = UUID()
        let text: String
        let date: Date
    }

    static let storeURL = AppPaths.support.appendingPathComponent("clipboard.json")

    static let limit = 12

    private(set) var entries: [Entry] = [] {
        didSet { save() }
    }
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let storeURL: URL?

    /// `storeURL: nil` keeps the history in memory only (tests).
    init(storeURL: URL? = ClipboardService.storeURL) {
        self.storeURL = storeURL
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Array(saved.prefix(Self.limit))
    }

    private func save() {
        guard let storeURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    /// Password managers mark their items with these types; those are skipped.
    private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "com.agilebits.onepassword", "com.apple.is-remote-clipboard"
    ]

    func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.concealedTypes) else { return }
        guard let text = pasteboard.string(forType: .string) else { return }
        record(text)
    }

    /// Adds one entry: newest first, no duplicates, capped.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.text == trimmed }
        entries.insert(Entry(text: trimmed, date: .now), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// Puts an entry back on the clipboard (without re-recording it).
    func copy(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        record(entry.text)
    }

    func clear() {
        entries.removeAll()
    }
}
