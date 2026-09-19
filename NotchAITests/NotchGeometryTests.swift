import CoreGraphics
import Testing
@testable import NotchAI

/// Values measured on the 14" MacBook Pro this was built on (2026-09-19).
private let macBookPro14 = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         safeAreaTop: 32,
                                         leftAuxiliaryWidth: 665,
                                         rightAuxiliaryWidth: 662,
                                         menuBarHeight: 32)

@Test func notchIsDerivedFromAuxiliaryAreas() {
    #expect(macBookPro14.hasPhysicalNotch)
    #expect(macBookPro14.notchRect == CGRect(x: 665, y: 950, width: 185, height: 32))
}

@Test func collapsedPanelAddsWingsOnBothSides() {
    #expect(macBookPro14.collapsedSize == CGSize(width: 185 + NotchGeometry.wingWidth * 2, height: 32))
}

@Test func windowIsTopAlignedAndCenteredOnNotch() {
    let frame = macBookPro14.windowFrame
    #expect(frame.maxY == 982)
    #expect(frame.midX == macBookPro14.notchRect.midX)
    #expect(frame.width >= macBookPro14.expandedSize.width)
}

@Test func hitRectsHangFromTheTopEdge() {
    let collapsed = macBookPro14.hitRect(expanded: false)
    let expanded = macBookPro14.hitRect(expanded: true)
    #expect(collapsed.maxY == 982 && expanded.maxY == 982)
    #expect(collapsed.contains(CGPoint(x: 700, y: 960)))
    #expect(!collapsed.contains(CGPoint(x: 700, y: 900)))
    #expect(expanded.contains(CGPoint(x: 700, y: 900)))
}

@Test func secondaryNotchedScreenUsesItsOwnOrigin() {
    // Built-in display arranged below an external monitor.
    let geometry = NotchGeometry(screenFrame: CGRect(x: 200, y: -982, width: 1512, height: 982),
                                 safeAreaTop: 32, leftAuxiliaryWidth: 665, rightAuxiliaryWidth: 662,
                                 menuBarHeight: 32)
    #expect(geometry.notchRect == CGRect(x: 865, y: -32, width: 185, height: 32))
    #expect(geometry.windowFrame.maxY == 0)
}

@Test func screenWithoutNotchFallsBackToCenteredPill() {
    let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                 safeAreaTop: 0, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil,
                                 menuBarHeight: 25)
    #expect(!geometry.hasPhysicalNotch)
    #expect(geometry.notchRect == CGRect(x: 1280, y: 1415, width: 0, height: 25))
    #expect(geometry.collapsedSize.width == NotchGeometry.wingWidth * 2)
}

@Test func hiddenMenuBarUsesDefaultHeight() {
    let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                 safeAreaTop: 0, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil,
                                 menuBarHeight: 0)
    #expect(geometry.notchHeight == NotchGeometry.fallbackMenuBarHeight)
}

@MainActor
@Test func hoverExpandsAfterDelayAndLeavingCollapses() async throws {
    let model = NotchViewModel(geometry: macBookPro14)
    #expect(model.updateMouse(CGPoint(x: 700, y: 970)))
    #expect(!model.isExpanded)
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.isExpanded)

    #expect(!model.updateMouse(CGPoint(x: 100, y: 100)))
    try await Task.sleep(for: .milliseconds(600))
    #expect(!model.isExpanded)
}

@MainActor
@Test func briefHoverDoesNotExpand() async throws {
    let model = NotchViewModel(geometry: macBookPro14)
    model.updateMouse(CGPoint(x: 700, y: 970))
    model.updateMouse(CGPoint(x: 100, y: 100))
    try await Task.sleep(for: .milliseconds(300))
    #expect(!model.isExpanded)
}

@MainActor
@Test func keepsOpenIgnoresMouseLeaving() async throws {
    let model = NotchViewModel(geometry: macBookPro14)
    model.setKeepsOpen(true)
    model.expand()
    model.updateMouse(CGPoint(x: 700, y: 900))
    model.updateMouse(CGPoint(x: 100, y: 100))
    try await Task.sleep(for: .milliseconds(600))
    #expect(model.isExpanded)
}

@Test func idleNotchShrinksToTheCharacter() {
    #expect(macBookPro14.compactCollapsedSize.width == 185 + NotchGeometry.compactWingWidth * 2)
    #expect(macBookPro14.compactCollapsedSize.width < macBookPro14.collapsedSize.width)
    // The wide-wing area is not part of the hover target while compact.
    let wingPoint = CGPoint(x: 665 - 60, y: 970)
    #expect(macBookPro14.hitRect(expanded: false).contains(wingPoint))
    #expect(!macBookPro14.hitRect(expanded: false, compact: true).contains(wingPoint))
}

@MainActor
@Test func pinnedPanelStaysOpenWhenTheFieldLosesFocus() async throws {
    let model = NotchViewModel(geometry: macBookPro14)
    model.pin()
    model.setKeepsOpen(false)
    model.updateMouse(CGPoint(x: 100, y: 100))
    try await Task.sleep(for: .milliseconds(600))
    #expect(model.isExpanded)
}
