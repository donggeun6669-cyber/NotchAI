import Foundation

/// Where an app built from this code keeps its files. NotchAI and the friend app use the names
/// they always had; another app (NotchDesk) names its own folders in its Info.plist, so two of
/// them on one Mac never share a clipboard history, a launcher list or a recordings folder.
enum AppPaths {
    /// `~/Library/Application Support/<NotchDataFolder>` — "NotchAI" unless Info.plist says otherwise.
    nonisolated static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(info("NotchDataFolder") ?? "NotchAI")

    /// `~/Documents/<NotchRecordingFolder>` — "Lecture-Recordings" unless Info.plist says otherwise.
    nonisolated static let recordings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent(info("NotchRecordingFolder") ?? "Lecture-Recordings")

    nonisolated private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
