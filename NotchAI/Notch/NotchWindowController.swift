import AppKit
import SwiftUI

/// Borderless panel that never activates the app, so hovering or clicking the notch
/// does not pull focus away from the window the user is working in.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // needed later for the prompt field
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let model: NotchViewModel
    private let app: AppModel
    private var mouseTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    init(app: AppModel) {
        self.app = app
        let screen = NotchGeometry.preferredScreen()
        let geometry = screen.map(NotchGeometry.init(screen:))
            ?? NotchGeometry(screenFrame: .zero, safeAreaTop: 0, leftAuxiliaryWidth: nil,
                             rightAuxiliaryWidth: nil, menuBarHeight: 0)
        model = NotchViewModel(geometry: geometry)

        panel = NotchPanel(contentRect: geometry.windowFrame,
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

        let hosting = NSHostingView(rootView: NotchView(model: model, app: app))
        hosting.sizingOptions = []         // the window frame comes from NotchGeometry, not SwiftUI
        panel.contentView = hosting

        // Typing in the command field made the panel key. Once it closes, hand the keyboard back
        // to the app the user was in (it stayed frontmost because the panel never activates).
        model.onCollapse = { [weak panel] in
            guard let panel, panel.isKeyWindow else { return }
            panel.makeFirstResponder(nil)
            let front = NSWorkspace.shared.frontmostApplication
            if front != .current { front?.activate() } else { NSApp.deactivate() }
        }
    }

    func show(startExpanded: Bool = false) {
        if startExpanded {
            model.setKeepsOpen(true)
            model.expand()
        }
        panel.setFrame(model.geometry.windowFrame, display: true)
        panel.orderFrontRegardless()

        // Polling the cursor needs no Accessibility / Input Monitoring permission.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    private func trackMouse() {
        let inside = model.updateMouse(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
    }

    /// Displays were added, removed or rearranged: move to the notched screen (or the fallback).
    private func relayout() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        guard geometry != model.geometry else { return }
        model.collapse()
        model.geometry = geometry
        panel.setFrame(geometry.windowFrame, display: true)
    }
}
