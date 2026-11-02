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
    /// Keeps the panel open when the mouse leaves: something is typed in the message field.
    private(set) var keepsOpen = false
    /// Held open regardless of the mouse (the `-startExpanded` launch flag, for screenshots).
    private(set) var isPinned = false
    @ObservationIgnored var onCollapse: (() -> Void)?
    /// Whether the collapsed notch should shrink to just the character (agent idle).
    /// A closure so SwiftUI tracks the agent state it reads.
    @ObservationIgnored var isCompact: () -> Bool = { false }
    /// Whether the wings hold only a recording's clock and meter, which need less than words do.
    @ObservationIgnored var isClock: () -> Bool = { false }
    /// A panel shown beside the open notch (NotchAI's 결재): the mouse over it keeps the notch open.
    @ObservationIgnored var besideRect: CGRect?

    @ObservationIgnored private var pendingChange: Task<Void, Never>?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var currentSize: CGSize {
        if isExpanded { return geometry.expandedSize }
        if isCompact() { return geometry.compactCollapsedSize }
        return isClock() ? geometry.clockCollapsedSize : geometry.collapsedSize
    }

    /// Each wing's width in the strip, open or closed.
    var currentWing: CGFloat {
        if isCompact() { return geometry.layout.narrowWing }
        return isClock() ? geometry.layout.clockWing : geometry.layout.wideWing
    }

    func expand() {
        pendingChange?.cancel()
        isExpanded = true
    }

    func collapse() {
        pendingChange?.cancel()
        isExpanded = false
    }

    func pin() {
        isPinned = true
        expand()
    }

    func setKeepsOpen(_ keep: Bool) {
        keepsOpen = keep
        // Focus left the panel while the mouse is already elsewhere: close now-ish.
        if !keep && !isPinned && isExpanded && !isHovering {
            schedule(after: Self.collapseDelay) { $0.isExpanded = false }
        }
    }

    /// Called with the global mouse position. Returns whether the mouse is over the panel,
    /// which decides if the window should take clicks or let them fall through.
    @discardableResult
    func updateMouse(_ point: CGPoint) -> Bool {
        let beside = isExpanded ? besideRect.map { $0.insetBy(dx: -14, dy: -6).contains(point) } ?? false : false
        let inside = beside || geometry.hitRect(expanded: isExpanded, compact: !isExpanded && isCompact(),
                                                  clock: !isExpanded && isClock())
            .insetBy(dx: -4, dy: -4).contains(point)
        guard inside != isHovering else { return inside }
        isHovering = inside
        pendingChange?.cancel()

        if inside && !isExpanded {
            schedule(after: Self.expandDelay) { $0.isExpanded = true }
        } else if !inside && isExpanded && !keepsOpen && !isPinned {
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
