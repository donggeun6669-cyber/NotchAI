import AppKit
import Observation

/// Recent clipboard entries, kept in memory only (never written to disk) and capped, so the
/// history disappears when the app quits.
@MainActor
@Observable
final class ClipboardService {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    static let limit = 12

    private(set) var entries: [Entry] = []
    private var lastChangeCount = NSPasteboard.general.changeCount

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
