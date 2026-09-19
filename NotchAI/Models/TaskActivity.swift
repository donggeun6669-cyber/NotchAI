import Foundation

/// One line in the "recent activity" list, e.g. "Editing LoginView.swift".
struct TaskActivity: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isDone: Bool
    let date: Date
}
