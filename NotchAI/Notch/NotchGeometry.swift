import AppKit

/// How big the panel is beside and below the notch. Each app hands in its own: NotchDesk keeps
/// these defaults; NotchAI sizes the open panel to the parts that are switched on (2026-11-01).
struct NotchLayout: Equatable {
    /// Each wing beside the notch when there is nothing to say.
    var narrowWing: CGFloat = NotchGeometry.compactWingWidth
    /// Each wing when there is (a recording clock, status words).
    var wideWing: CGFloat = NotchGeometry.wingWidth
    /// The open panel below the notch row.
    var body = CGSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.expandedBodyHeight)
}

/// Where the notch is on one screen, and how big the panel is in each state.
/// Pure values (no NSScreen inside) so it can be unit-tested.
struct NotchGeometry: Equatable {
    /// Width of the character / status area on each side of the physical notch.
    static let wingWidth: CGFloat = 112
    /// Narrower wings while the agent is idle: just room for the character.
    static let compactWingWidth: CGFloat = 32
    /// Small outward curve where the panel meets the top edge of the screen.
    static let earRadius: CGFloat = 6
    /// Extra room around the panel so the expanded shadow is not clipped.
    static let shadowPadding: CGFloat = 20
    static let minExpandedWidth: CGFloat = 700
    /// Height of the island on a screen without a notch.
    static let islandHeight: CGFloat = 32
    static let expandedBodyHeight: CGFloat = 392
    static let fallbackMenuBarHeight: CGFloat = 24

    let screenFrame: CGRect
    /// The physical notch in global screen coordinates. On a screen without a notch this is a
    /// zero-width rect at the top center, so the panel becomes a floating island.
    let notchRect: CGRect
    let hasPhysicalNotch: Bool
    let menuBarHeight: CGFloat
    let layout: NotchLayout

    /// A screen with no notch gets an iPhone-style island: the same rounded shape, still hanging
    /// from the top edge (only the shape differs from the real notch, not the place).
    var isIsland: Bool { !hasPhysicalNotch }

    init(screenFrame: CGRect,
         safeAreaTop: CGFloat,
         leftAuxiliaryWidth: CGFloat?,
         rightAuxiliaryWidth: CGFloat?,
         menuBarHeight: CGFloat,
         layout: NotchLayout = NotchLayout()) {
        self.screenFrame = screenFrame
        self.menuBarHeight = menuBarHeight
        self.layout = layout
        if safeAreaTop > 0, let left = leftAuxiliaryWidth, let right = rightAuxiliaryWidth,
           screenFrame.width - left - right > 0 {
            // Only the widths are used, so this does not depend on which coordinate space
            // AppKit reports the auxiliary areas in.
            notchRect = CGRect(x: screenFrame.minX + left,
                               y: screenFrame.maxY - safeAreaTop,
                               width: screenFrame.width - left - right,
                               height: safeAreaTop)
            hasPhysicalNotch = true
        } else {
            let height = menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight
            notchRect = CGRect(x: screenFrame.midX, y: screenFrame.maxY - height, width: 0, height: height)
            hasPhysicalNotch = false
        }
    }

    init(screen: NSScreen, layout: NotchLayout = NotchLayout()) {
        self.init(screenFrame: screen.frame,
                  safeAreaTop: screen.safeAreaInsets.top,
                  leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
                  rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width,
                  menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
                  layout: layout)
    }

    /// The built-in notched display if there is one, otherwise the main display.
    @MainActor static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    var notchHeight: CGFloat { hasPhysicalNotch ? notchRect.height : Self.islandHeight }

    var collapsedSize: CGSize {
        CGSize(width: notchRect.width + layout.wideWing * 2, height: notchHeight)
    }

    var compactCollapsedSize: CGSize {
        CGSize(width: notchRect.width + layout.narrowWing * 2, height: notchHeight)
    }

    var expandedSize: CGSize {
        var width = max(layout.body.width, collapsedSize.width)
        // A portrait display is narrower than the panel wants to be.
        let room = screenFrame.width - (Self.earRadius + Self.shadowPadding) * 2
        if screenFrame.width > 0, room > 0 { width = min(width, room) }
        return CGSize(width: width, height: notchHeight + layout.body.height)
    }

    /// The borderless window is fixed at the expanded size; SwiftUI draws the current shape inside it.
    var windowFrame: CGRect {
        let width = expandedSize.width + Self.earRadius * 2 + Self.shadowPadding * 2
        let height = expandedSize.height + Self.shadowPadding
        return CGRect(x: notchRect.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Where a panel beside the open notch goes (NotchAI's 결재, 2026-11-01): to the right, top-aligned
    /// with the panel body; to the left when the right side has no room; under the panel when
    /// neither side does (a portrait display).
    static func sideFrame(beside panel: CGRect, in screen: CGRect, size: CGSize, top: CGFloat,
                          gap: CGFloat = 10, margin: CGFloat = 8) -> CGRect {
        let height = min(size.height, top - screen.minY - margin)
        if panel.maxX + gap + size.width <= screen.maxX - margin {
            return CGRect(x: panel.maxX + gap, y: top - height, width: size.width, height: height)
        }
        if panel.minX - gap - size.width >= screen.minX + margin {
            return CGRect(x: panel.minX - gap - size.width, y: top - height, width: size.width, height: height)
        }
        let below = panel.minY - gap
        let x = min(max(panel.maxX - size.width, screen.minX + margin), screen.maxX - margin - size.width)
        let fitted = min(height, below - screen.minY - margin)
        return CGRect(x: x, y: below - fitted, width: size.width, height: fitted)
    }

    /// Area (global coordinates) that reacts to the mouse in each state.
    func hitRect(expanded: Bool, compact: Bool = false) -> CGRect {
        let size = expanded ? expandedSize : (compact ? compactCollapsedSize : collapsedSize)
        return CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}
