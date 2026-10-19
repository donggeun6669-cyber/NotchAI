import Foundation

/// NotchDesk's launcher starts empty: the places are the user's to add.
extension LauncherService {
    nonisolated static func defaultItems() -> [Item] { [] }
    nonisolated static var hasDefaultList: Bool { false }
}
