/*
 RunCatStatusItem.swift — NotchAI

 The running cat in the menu bar, from RunCat Neo (commit 592cd60, 2026-10-19):
   RunnerLayer.swift, BackgroundLayer.swift, RunnerBarView.swift, RunnerBar.swift,
   RunnerService.swift (the speed), NSImage+Extension.swift (normalize), FrameOrder.swift
   Copyright 2026 Kyome22 (Takuto Nakamura)

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

 Modified for NotchAI on 2026-11-09:
   - only the cat runner; no runner picker, custom runners, dashboard, settings or metrics bar;
   - an AppKit NSStatusItem instead of a SwiftUI MenuBarExtra (NotchAI has no SwiftUI scenes);
   - the layers take the menu bar's height and the screen's scale instead of 22 pt and 2×;
   - the speed comes from NotchAI's SystemMonitor (the same CPU number the notch shows);
   - a click opens or closes the notch instead of RunCat's dashboard.
 The animation itself is RunCat Neo's: a discrete CAKeyframeAnimation over the frames, two frames a
 second at speed 1, its speed set to CPU% / 5 clamped to 1…20 (RunnerService.updateRunnerSpeed,
 with 「slower under load」 off, RunCat's default).
 */

import AppKit
import CoreImage.CIFilterBuiltins

/// RunCat Neo's speed for a CPU share (0…1): 1 at idle up to 20 at full load.
enum RunCatSpeed {
    static func speed(cpu: Double) -> Float {
        max(1.0, min(20.0, Float(cpu * 100) / 5.0))
    }

    /// Seconds per frame at a speed (frames are shown two a second at speed 1).
    static func secondsPerFrame(speed: Float) -> Double { 0.5 / Double(speed) }
}

@MainActor
final class RunCatStatusItem: NSObject {
    /// Left click (open/close the notch on the screen the menu bar is on).
    var onClick: ((NSScreen?) -> Void)?
    /// 「고양이 숨기기」 in the right-click menu.
    var onHide: (() -> Void)?

    private let item: NSStatusItem
    private let frames: [NSImage]
    private var runnerLayer: RunnerLayer?
    private var backgroundLayer: BackgroundLayer?
    private var appearanceObservation: NSKeyValueObservation?
    private var windowObservation: NSKeyValueObservation?
    private var lastPercent = -1
    private var speed: Float = 1

    /// RunCat's cat frames, in order (`FrameOrder.ascending(5)`), 18 pt tall as `normalize()` makes them.
    static func loadFrames(bundle: Bundle = .main) -> [NSImage] {
        (0..<5).compactMap { index in
            guard let url = bundle.url(forResource: "runcat-cat-frame-\(index)", withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            let scale = image.size.height / 18.0
            image.size = CGSize(width: image.size.width / scale, height: image.size.height / scale)
            image.isTemplate = true   // the cat is a template runner: it takes the menu bar's text colour
            return image
        }
    }

    init?(frames: [NSImage] = RunCatStatusItem.loadFrames()) {
        guard frames.count == 5 else { return nil }
        self.frames = frames
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "NotchAI.RunCat"
        guard let button = item.button else { return nil }
        // Drawn on the menu bars of the other displays, where layer animations do not render
        // (RunCat Neo's fallback); erased by `BackgroundLayer` on the active one.
        let still = frames[0].copy() as! NSImage
        still.isTemplate = true
        button.image = still
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("NotchAI · CPU")
        button.toolTip = "CPU"
        installLayers(in: button)
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] button, _ in
            MainActor.assumeIsolated { self?.updateColor(for: button) }
        }
        // The status item moves to another display's menu bar: match that screen's scale and height.
        windowObservation = button.observe(\.window, options: [.new]) { [weak self] button, _ in
            MainActor.assumeIsolated { self?.layout(in: button) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func remove() {
        appearanceObservation = nil
        windowObservation = nil
        NotificationCenter.default.removeObserver(self)
        runnerLayer?.removeAllAnimations()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// The CPU share from `SystemMonitor`: the cat's speed and the tooltip.
    func update(cpu: Double) {
        let newSpeed = RunCatSpeed.speed(cpu: cpu)
        if newSpeed != speed {
            speed = newSpeed
            runnerLayer?.setSpeed(newSpeed)
        }
        let percent = Int((cpu * 100).rounded())
        if percent != lastPercent, let button = item.button {
            lastPercent = percent
            button.toolTip = "CPU \(percent)% · 누르면 노치 열기"
            button.setAccessibilityValue("CPU \(percent)%")
        }
    }

    // MARK: Layers

    private func installLayers(in button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }
        let size = frames[0].size
        item.length = ceil(size.width) + 8
#if arch(arm64)
        let background = BackgroundLayer()
        host.addSublayer(background)
        backgroundLayer = background
#endif
        let runner = RunnerLayer()
        host.addSublayer(runner)
        runnerLayer = runner
        layout(in: button)
        runner.setFrames(frames, isTemplate: true)
        runner.setSpeed(speed)
    }

    private func layout(in button: NSStatusBarButton) {
        let size = frames[0].size
        let bounds = button.bounds
        let origin = CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded())
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        runnerLayer?.place(CGRect(origin: origin, size: size), scale: scale)
        backgroundLayer?.place(bounds, scale: scale)
    }

    @objc private func screensChanged() {
        guard let button = item.button else { return }
        layout(in: button)
    }

    private func updateColor(for button: NSStatusBarButton) {
        var tint = NSColor.black.cgColor
        (button.window?.effectiveAppearance ?? button.effectiveAppearance).performAsCurrentDrawingAppearance {
            tint = NSColor.textColor.cgColor
        }
        runnerLayer?.setColor(tint, isTemplate: true)
    }

    // MARK: Click

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            onClick?(sender.window?.screen)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "노치 열기 · 닫기", action: #selector(openNotch), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let hide = NSMenuItem(title: "메뉴바 고양이 숨기기", action: #selector(hideCat), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let credit = NSMenuItem(title: "고양이: RunCat Neo (Apache 2.0)", action: nil, keyEquivalent: "")
        credit.isEnabled = false
        menu.addItem(credit)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "NotchAI 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
        button.performClick(nil)   // shows the menu under the cat
        item.menu = nil            // left clicks go back to the action
    }

    @objc private func openNotch() { onClick?(item.button?.window?.screen) }
    @objc private func hideCat() { onHide?() }
}

// MARK: - RunCat Neo's layers

/// Erases the still image under the animation on the active display (RunCat Neo's BackgroundLayer).
/// The `sourceOut` background filter does not work on Intel Macs, so it is installed on arm64 only.
private final class BackgroundLayer: CALayer {
    override init() {
        super.init()
        masksToBounds = true
        let filter = CIFilter.sourceOutCompositing()
        let rect = CGRect(x: 0, y: 0, width: 600, height: 120)
        filter.backgroundImage = CIImage(color: CIColor.blue).cropped(to: rect)
        backgroundFilters = [filter]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func place(_ rect: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        contentsScale = scale
        CATransaction.commit()
    }
}

/// The animation (RunCat Neo's RunnerLayer). A template runner's frames animate a mask over a
/// layer filled with the menu bar's text colour, so the cat is black or white like the icons
/// around it.
private final class RunnerLayer: CALayer {
    private let maskLayer = CALayer()
    private let animation = CAKeyframeAnimation(keyPath: "contents")

    override init() {
        super.init()
        contentsGravity = .left
        masksToBounds = true
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func place(_ rect: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        maskLayer.frame = CGRect(origin: .zero, size: rect.size)
        contentsScale = scale
        maskLayer.contentsScale = scale
        CATransaction.commit()
    }

    func setFrames(_ frames: [NSImage], isTemplate: Bool) {
        animation.values = frames
        animation.duration = Double(frames.count) / 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAllAnimations()
        maskLayer.removeAllAnimations()
        if isTemplate {
            if mask == nil { maskLayer.speed = speed }
            timeOffset = .zero
            beginTime = .zero
            speed = 1.0
            mask = maskLayer
            maskLayer.add(animation, forKey: "running")
        } else {
            if mask != nil { speed = maskLayer.speed }
            mask = nil
            add(animation, forKey: "running")
        }
        CATransaction.commit()
    }

    func setColor(_ tint: CGColor, isTemplate: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundColor = isTemplate ? tint : nil
        CATransaction.commit()
    }

    /// Changes the speed without a jump: the animation continues from the frame it is on.
    func setSpeed(_ speed: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if mask == nil {
            timeOffset = convertTime(CACurrentMediaTime(), from: nil)
            beginTime = CACurrentMediaTime()
            self.speed = speed
        } else {
            maskLayer.timeOffset = maskLayer.convertTime(CACurrentMediaTime(), from: nil)
            maskLayer.beginTime = CACurrentMediaTime()
            maskLayer.speed = speed
        }
        CATransaction.commit()
    }
}
