import AppKit

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
    static let minExpandedWidth: CGFloat = 640
    /// Height of the floating island on a screen without a notch.
    static let islandHeight: CGFloat = 32
    /// Gap between the menu bar and the island, so it reads as floating.
    static let islandGap: CGFloat = 6
    static let expandedBodyHeight: CGFloat = 392
    static let fallbackMenuBarHeight: CGFloat = 24

    let screenFrame: CGRect
    /// The physical notch in global screen coordinates. On a screen without a notch this is a
    /// zero-width rect at the top center, so the panel becomes a floating island.
    let notchRect: CGRect
    let hasPhysicalNotch: Bool
    let menuBarHeight: CGFloat

    /// A screen with no notch gets an iPhone-style island: a rounded shape floating below the
    /// menu bar instead of a shape growing out of the top edge.
    var isIsland: Bool { !hasPhysicalNotch }

    /// How far below the top edge the panel hangs. The island clears the menu bar; the real
    /// notch starts at the very top, because it is part of the hardware.
    var topInset: CGFloat {
        guard isIsland else { return 0 }
        return (menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight) + Self.islandGap
    }

    init(screenFrame: CGRect,
         safeAreaTop: CGFloat,
         leftAuxiliaryWidth: CGFloat?,
         rightAuxiliaryWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.menuBarHeight = menuBarHeight
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

    init(screen: NSScreen) {
        self.init(screenFrame: screen.frame,
                  safeAreaTop: screen.safeAreaInsets.top,
                  leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
                  rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width,
                  menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The built-in notched display if there is one, otherwise the main display.
    @MainActor static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    var notchHeight: CGFloat { hasPhysicalNotch ? notchRect.height : Self.islandHeight }

    var collapsedSize: CGSize {
        CGSize(width: notchRect.width + Self.wingWidth * 2, height: notchHeight)
    }

    var compactCollapsedSize: CGSize {
        CGSize(width: notchRect.width + Self.compactWingWidth * 2, height: notchHeight)
    }

    var expandedSize: CGSize {
        var width = max(Self.minExpandedWidth, collapsedSize.width)
        // A portrait display is narrower than the panel wants to be.
        let room = screenFrame.width - (Self.earRadius + Self.shadowPadding) * 2
        if screenFrame.width > 0, room > 0 { width = min(width, room) }
        return CGSize(width: width, height: notchHeight + Self.expandedBodyHeight)
    }

    /// The borderless window is fixed at the expanded size; SwiftUI draws the current shape inside it.
    var windowFrame: CGRect {
        let width = expandedSize.width + Self.earRadius * 2 + Self.shadowPadding * 2
        let height = expandedSize.height + Self.shadowPadding
        return CGRect(x: notchRect.midX - width / 2, y: screenFrame.maxY - topInset - height,
                      width: width, height: height)
    }

    /// Area (global coordinates) that reacts to the mouse in each state.
    func hitRect(expanded: Bool, compact: Bool = false) -> CGRect {
        let size = expanded ? expandedSize : (compact ? compactCollapsedSize : collapsedSize)
        return CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - topInset - size.height,
                      width: size.width, height: size.height)
    }
}
