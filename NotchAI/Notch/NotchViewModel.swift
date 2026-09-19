import Foundation
import Observation

/// Expanded / collapsed state and the hover rules that drive it.
@MainActor
@Observable
final class NotchViewModel {
    static let expandDelay: Duration = .milliseconds(150)
    static let collapseDelay: Duration = .milliseconds(400)

    var geometry: NotchGeometry
    private(set) var isExpanded = false {
        didSet { if oldValue && !isExpanded { onCollapse?() } }
    }
    private(set) var isHovering = false
    /// Keeps the panel open when the mouse leaves (while typing a command, or the debug launch flag).
    private(set) var keepsOpen = false
    @ObservationIgnored var onCollapse: (() -> Void)?

    @ObservationIgnored private var pendingChange: Task<Void, Never>?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var currentSize: CGSize { isExpanded ? geometry.expandedSize : geometry.collapsedSize }

    func expand() {
        pendingChange?.cancel()
        isExpanded = true
    }

    func collapse() {
        pendingChange?.cancel()
        isExpanded = false
    }

    func setKeepsOpen(_ keep: Bool) {
        keepsOpen = keep
        // Focus left the panel while the mouse is already elsewhere: close now-ish.
        if !keep && isExpanded && !isHovering {
            schedule(after: Self.collapseDelay) { $0.isExpanded = false }
        }
    }

    /// Called with the global mouse position. Returns whether the mouse is over the panel,
    /// which decides if the window should take clicks or let them fall through.
    @discardableResult
    func updateMouse(_ point: CGPoint) -> Bool {
        let inside = geometry.hitRect(expanded: isExpanded).insetBy(dx: -4, dy: -4).contains(point)
        guard inside != isHovering else { return inside }
        isHovering = inside
        pendingChange?.cancel()

        if inside && !isExpanded {
            schedule(after: Self.expandDelay) { $0.isExpanded = true }
        } else if !inside && isExpanded && !keepsOpen {
            schedule(after: Self.collapseDelay) { $0.isExpanded = false }
        }
        return inside
    }

    private func schedule(after delay: Duration, _ change: @escaping @MainActor (NotchViewModel) -> Void) {
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            change(self)
        }
    }
}
