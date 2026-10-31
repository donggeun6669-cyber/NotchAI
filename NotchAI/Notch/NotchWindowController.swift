import AppKit
import SwiftUI

/// Borderless panel that never activates the app, so hovering or clicking the notch
/// does not pull focus away from the window the user is working in.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // needed later for the prompt field
    override var canBecomeMain: Bool { false }
}

/// A panel that appears beside the open notch while the app has something for it (NotchAI's 결재,
/// 2026-11-01). Apps without one leave `NotchWindowController.beside` nil.
@MainActor
struct NotchBeside {
    let width: CGFloat
    /// Whether it should be up beside an open notch now.
    let isWanted: () -> Bool
    /// The height its content asks for.
    let contentHeight: () -> CGFloat
    let makeView: () -> NSView
}

extension Notification.Name {
    /// Posted when the "show on every display" setting changes.
    static let notchScreensChanged = Notification.Name("NotchAI.screensChanged")
}

/// One panel per display. The built-in screen gets the real notch; the others get the same
/// panel hanging from the top edge, because everything in it is worth seeing from whichever
/// screen the user is looking at.
@MainActor
final class NotchWindowController {
    /// A panel and its state on one display.
    private final class Screen {
        let displayID: CGDirectDisplayID
        let panel: NotchPanel
        let model: NotchViewModel
        var beside: NotchPanel?

        init(displayID: CGDirectDisplayID, panel: NotchPanel, model: NotchViewModel) {
            self.displayID = displayID
            self.panel = panel
            self.model = model
        }
    }

    static let allScreensKey = "showsOnAllScreens"
    /// Whether every display gets a panel. On by default: the user asked for all three.
    static var showsOnAllScreens: Bool {
        get { UserDefaults.standard.object(forKey: allScreensKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: allScreensKey)
            NotificationCenter.default.post(name: .notchScreensChanged, object: nil)
        }
    }

    private let app: AppModel
    private var screens: [Screen] = []
    /// The panel beside the open notch, if this app has one.
    var beside: NotchBeside?
    private var mouseTimer: Timer?
    private var mouseInterval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var startExpanded = false

    init(app: AppModel) {
        self.app = app
    }

    func show(startExpanded: Bool = false) {
        self.startExpanded = startExpanded
        rebuild()

        // Polling the cursor needs no Accessibility / Input Monitoring permission.
        scheduleMouseTimer(Self.fastInterval)
        for name in [NSApplication.didChangeScreenParametersNotification, .notchScreensChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            })
        }
    }

    /// Displays were added, removed or rearranged: keep one panel per display in use.
    private func rebuild() {
        let wanted = Self.targetScreens()
        let wantedIDs = Set(wanted.compactMap(Self.displayID))

        for screen in screens where !wantedIDs.contains(screen.displayID) {
            screen.model.collapse()
            screen.panel.orderOut(nil)
            screen.beside?.orderOut(nil)
        }
        screens.removeAll { !wantedIDs.contains($0.displayID) }

        for nsScreen in wanted {
            guard let id = Self.displayID(of: nsScreen) else { continue }
            let geometry = NotchGeometry(screen: nsScreen, layout: app.notchLayout)
            if let existing = screens.first(where: { $0.displayID == id }) {
                guard geometry != existing.model.geometry else { continue }
                existing.model.collapse()
                existing.model.geometry = geometry
                existing.panel.setFrame(geometry.windowFrame, display: true)
            } else {
                screens.append(make(geometry: geometry, displayID: id))
            }
        }
    }

    /// Every display, or only the notched one when the user turned the others off.
    private static func targetScreens() -> [NSScreen] {
        guard showsOnAllScreens else { return [NotchGeometry.preferredScreen()].compactMap { $0 } }
        return NSScreen.screens
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func make(geometry: NotchGeometry, displayID: CGDirectDisplayID) -> Screen {
        let model = NotchViewModel(geometry: geometry)
        let panel = NotchPanel(contentRect: geometry.windowFrame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // SwiftUI draws its own shadow
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true    // clicks fall through until the mouse is over the panel

        // Narrow unless the app has something that needs words (2026-10-19, 동근님: 「괜히 길어지면
        // 불편」): in NotchAI only a recording's clock or a failed recording (2026-11-01).
        model.isCompact = { [app] in app.collapsedIsNarrow }

        let hosting = NSHostingView(rootView: NotchView(model: model, app: app))
        hosting.sizingOptions = []         // the window frame comes from NotchGeometry, not SwiftUI
        panel.contentView = hosting

        // Typing in a field made the panel key. Once it closes, hand the keyboard back to the app
        // the user was in (it stayed frontmost because the panel never activates).
        model.onCollapse = { [weak panel] in
            guard let panel, panel.isKeyWindow else { return }
            panel.makeFirstResponder(nil)
            let front = NSWorkspace.shared.frontmostApplication
            if front != .current { front?.activate() } else { NSApp.deactivate() }
        }

        // Only the built-in screen starts pinned open (screenshots and debugging).
        if startExpanded, geometry.hasPhysicalNotch { model.pin() }
        panel.setFrame(geometry.windowFrame, display: true)
        panel.orderFrontRegardless()
        return Screen(displayID: displayID, panel: panel, model: model)
    }

    /// 20 times a second near the top of a screen or while a panel is open, 5 times elsewhere.
    /// The cursor is far from every notch most of the time, and checking it 20 times a second
    /// regardless was most of what the app cost when nothing happened (2026-11-01).
    static let fastInterval: TimeInterval = 1.0 / 20.0
    static let slowInterval: TimeInterval = 1.0 / 5.0
    /// How far below the top edge counts as "on the way to the notch".
    static let nearTop: CGFloat = 140

    private func scheduleMouseTimer(_ interval: TimeInterval) {
        mouseTimer?.invalidate()
        mouseInterval = interval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        timer.tolerance = interval * 0.2
        mouseTimer = timer
    }

    /// The cursor is on one screen at a time, so at most one panel reacts to it.
    private func trackMouse() {
        let location = NSEvent.mouseLocation
        var near = false
        for screen in screens {
            let inside = screen.model.updateMouse(location)
            if screen.panel.ignoresMouseEvents == inside {
                screen.panel.ignoresMouseEvents = !inside
            }
            updateBeside(screen)
            let frame = screen.model.geometry.screenFrame
            if screen.model.isExpanded || screen.model.isHovering
                || (frame.minX...frame.maxX).contains(location.x)
                    && (frame.maxY - Self.nearTop...frame.maxY + 1).contains(location.y) {
                near = true
            }
        }
        let wanted = near ? Self.fastInterval : Self.slowInterval
        if wanted != mouseInterval { scheduleMouseTimer(wanted) }
    }

    // MARK: Beside the open notch

    /// Shows, moves or hides the panel beside one screen's notch. Runs with the cursor checks, so it
    /// follows the notch opening and closing without a timer of its own.
    private func updateBeside(_ screen: Screen) {
        guard let beside, screen.model.isExpanded, beside.isWanted() else {
            if screen.beside?.isVisible == true { screen.beside?.orderOut(nil) }
            screen.model.besideRect = nil
            return
        }
        let geometry = screen.model.geometry
        let panelRect = geometry.hitRect(expanded: true)
        let top = geometry.screenFrame.maxY - geometry.notchHeight - 6
        let maxHeight = geometry.expandedSize.height + 140
        let height = min(max(beside.contentHeight(), 60), maxHeight)
        let frame = NotchGeometry.sideFrame(beside: panelRect, in: geometry.screenFrame,
                                            size: CGSize(width: beside.width, height: height), top: top)
        let panel = screen.beside ?? makeBeside(beside)
        screen.beside = panel
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        screen.model.besideRect = frame
    }

    private func makeBeside(_ beside: NotchBeside) -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = beside.makeView()
        panel.contentView = view
        return panel
    }
}
