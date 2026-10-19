import AppKit
import QuartzCore
import SwiftUI

/// The companion: a soft glowing body with two eyes. Claude is a rounded square in warm orange,
/// GPT a circle in teal; both share the same eyes and motion so they read as one family.
///
/// Drawn with Core Animation layers so the idle breathing runs in the window server instead of
/// re-rendering SwiftUI every frame.
struct AICharacterView: NSViewRepresentable {
    let kind: ProviderKind
    let state: AgentState
    var size: CGFloat = 18
    /// Provider letter badge; only legible at larger sizes.
    var showsMark: Bool = false

    func makeNSView(context: Context) -> CharacterLayerView {
        CharacterLayerView()
    }

    func updateNSView(_ view: CharacterLayerView, context: Context) {
        view.configure(.init(kind: kind, state: state, size: size, showsMark: showsMark))
        view.setAccessibilityLabel("\(kind.displayName), \(state.label)")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CharacterLayerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class CharacterLayerView: NSView {
    struct Config: Equatable {
        var kind: ProviderKind
        var state: AgentState
        var size: CGFloat
        var showsMark: Bool
    }

    private static let eyeColor = NSColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1).cgColor
    private static let blush = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.45, alpha: 0.32).cgColor
    private static let sweatColor = NSColor(srgbRed: 0.72, green: 0.90, blue: 1.0, alpha: 1).cgColor
    /// Arms, cheeks, sweat and thoughts need room to read; the collapsed notch keeps the plain head.
    static let detailSize: CGFloat = 26

    private var config: Config?
    /// Moves as a whole for the hop / shake.
    private let stage = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    /// Clicks go to the SwiftUI views around the character.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let config else { return }
        self.config = nil
        configure(config)
    }

    func configure(_ new: Config) {
        guard new != config else { return }
        let previousState = config?.state
        config = new
        rebuild(new)

        let s = new.size
        if previousState != nil, previousState != new.state, !reduceMotion {
            if new.state == .completed { stage.add(CharacterAnimations.hop(height: s * 0.14), forKey: "hop") }
            if new.state == .error { stage.add(CharacterAnimations.shake(distance: s * 0.06), forKey: "shake") }
        }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func rebuild(_ config: Config) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        let s = config.size
        stage.frame = CGRect(x: 0, y: 0, width: s, height: s)
        // Layers of a flipped NSView use top-left origin, like SwiftUI.
        stage.isGeometryFlipped = false
        let look = CharacterState(state: config.state, accent: config.kind.nsAccent)
        let animate = !reduceMotion

        // Glow behind the body.
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [look.glowColor.cgColor, look.glowColor.withAlphaComponent(0).cgColor]
        glow.locations = [0.3, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: -s * 0.45, y: -s * 0.45, width: s * 1.9, height: s * 1.9)
        glow.opacity = look.glowRange.lowerBound
        if animate {
            glow.add(CharacterAnimations.glow(period: look.pulsePeriod, from: look.glowRange.lowerBound,
                                              to: look.glowRange.upperBound), forKey: "glow")
        }
        stage.addSublayer(glow)

        let detailed = s >= Self.detailSize

        // The lean holds the tilt (and the idle sway) so it does not fight the breathing scale.
        let lean = CALayer()
        lean.frame = stage.bounds
        if detailed {
            lean.transform = CATransform3DMakeRotation(look.tilt, 0, 0, 1)
            if animate, look.pose == .rest {
                lean.add(CharacterAnimations.sway(angle: 0.035, period: look.pulsePeriod * 1.6), forKey: "sway")
            }
        }
        stage.addSublayer(lean)

        // Body and eyes breathe together.
        let group = CALayer()
        group.frame = stage.bounds
        if animate { group.add(CharacterAnimations.pulse(period: look.pulsePeriod, amount: look.pulseAmount), forKey: "pulse") }
        lean.addSublayer(group)

        // Arms sit behind the body so they read as sticking out of it.
        if detailed { makeArms(look: look, kind: config.kind, size: s, animate: animate).forEach(group.addSublayer) }

        let body = CALayer()
        body.frame = group.bounds
        body.backgroundColor = config.kind.nsAccent.cgColor
        body.cornerRadius = config.kind == .claude ? s * 0.36 : s / 2
        body.cornerCurve = .continuous
        body.masksToBounds = true
        let highlight = CAGradientLayer()
        highlight.frame = body.bounds
        highlight.colors = [NSColor.white.withAlphaComponent(0.32).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        highlight.startPoint = CGPoint(x: 0.5, y: 0)
        highlight.endPoint = CGPoint(x: 0.5, y: 0.55)
        body.addSublayer(highlight)
        group.addSublayer(body)

        group.addSublayer(makeEyes(look: look, size: s, animate: animate))
        if detailed, look.pose != .droop { makeCheeks(size: s).forEach(group.addSublayer) }

        // Sweat and thoughts stay outside the breathing group, so they keep their own rhythm.
        if detailed, animate {
            switch look.pose {
            case .work: makeSweat(size: s).forEach(lean.addSublayer)
            case .think: makeThoughts(size: s).forEach(lean.addSublayer)
            default: break
            }
        }

        if let badge = makeBadge(look.badge, size: s, animate: animate) { stage.addSublayer(badge) }
        if config.showsMark { stage.addSublayer(makeMark(kind: config.kind, size: s)) }
    }

    /// Two little arms, swung from the shoulder. What they do is the whole point of the pose.
    private func makeArms(look: CharacterState, kind: ProviderKind, size s: CGFloat, animate: Bool) -> [CALayer] {
        // left, right: resting angle, how far it swings, how fast.
        let (leftBase, rightBase, amount, period): (CGFloat, CGFloat, CGFloat, Double)
        switch look.pose {
        case .rest: (leftBase, rightBase, amount, period) = (0.42, -0.42, 0.09, 3.4)
        case .work: (leftBase, rightBase, amount, period) = (0.45, -0.45, 0.55, 0.5)
        case .think: (leftBase, rightBase, amount, period) = (0.45, -1.00, 0.05, 2.4)
        case .raiseHand: (leftBase, rightBase, amount, period) = (0.45, -2.45, 0.3, 0.7)
        case .cheer: (leftBase, rightBase, amount, period) = (2.40, -2.40, 0.2, 0.6)
        case .droop: (leftBase, rightBase, amount, period) = (0.28, -0.28, 0, 3.4)
        }

        let width = s * 0.11
        let length = s * 0.34
        let color = kind.nsAccent.blended(withFraction: 0.18, of: .black)?.cgColor ?? kind.nsAccent.cgColor
        return [(-1.0, leftBase, 0.0), (1.0, rightBase, 0.5)].map { side, base, phase in
            let arm = CALayer()
            arm.bounds = CGRect(x: 0, y: 0, width: width, height: length)
            arm.anchorPoint = CGPoint(x: 0.5, y: 0.1)   // the shoulder
            // Just outside the body, so the whole arm shows instead of a stub.
            // Clear of the body: Claude's rounded square is full width at this height, so an
            // arm any closer disappears behind it.
            arm.position = CGPoint(x: s / 2 + side * s * 0.54, y: s * 0.52)
            arm.cornerRadius = width / 2
            arm.backgroundColor = color
            // A round hand at the end reads better than a bare stick at this size.
            let hand = CALayer()
            let handSize = width * 1.35
            hand.bounds = CGRect(x: 0, y: 0, width: handSize, height: handSize)
            hand.position = CGPoint(x: width / 2, y: length * 0.93)
            hand.cornerRadius = handSize / 2
            hand.backgroundColor = color
            arm.addSublayer(hand)
            arm.transform = CATransform3DMakeRotation(base, 0, 0, 1)
            if animate, amount > 0 {
                arm.add(CharacterAnimations.armSwing(base: base, amount: amount, period: period,
                                                     phase: look.pose == .work ? phase : 0), forKey: "swing")
            }
            return arm
        }
    }

    private func makeCheeks(size s: CGFloat) -> [CALayer] {
        [-1.0, 1.0].map { side in
            let cheek = CALayer()
            cheek.bounds = CGRect(x: 0, y: 0, width: s * 0.17, height: s * 0.10)
            cheek.position = CGPoint(x: s / 2 + side * s * 0.27, y: s * 0.63)
            cheek.cornerRadius = s * 0.05
            cheek.backgroundColor = Self.blush
            return cheek
        }
    }

    /// Drops flying off the head: the "이거 힘들다" of the working state.
    private func makeSweat(size s: CGFloat) -> [CALayer] {
        [0.0, 0.75].map { delay in
            let drop = CALayer()
            drop.bounds = CGRect(x: 0, y: 0, width: s * 0.09, height: s * 0.12)
            drop.position = CGPoint(x: s * 0.80, y: s * 0.14)
            drop.cornerRadius = s * 0.045
            drop.backgroundColor = Self.sweatColor
            drop.opacity = 0
            drop.add(CharacterAnimations.sweat(distance: s * 0.26, period: 1.5, delay: delay), forKey: "sweat")
            return drop
        }
    }

    /// Three bubbles rising away from the head while it thinks.
    private func makeThoughts(size s: CGFloat) -> [CALayer] {
        let sizes: [CGFloat] = [0.09, 0.12, 0.15]
        let spots: [CGPoint] = [CGPoint(x: 0.78, y: 0.00), CGPoint(x: 0.90, y: -0.14), CGPoint(x: 1.02, y: -0.30)]
        return (0..<3).map { index in
            let bubble = CALayer()
            let d = s * sizes[index]
            bubble.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            bubble.position = CGPoint(x: s * spots[index].x, y: s * spots[index].y)
            bubble.cornerRadius = d / 2
            bubble.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
            bubble.opacity = 0
            bubble.add(CharacterAnimations.thought(index: index, period: 1.9, rise: s * 0.10), forKey: "think")
            return bubble
        }
    }

    private func makeEyes(look: CharacterState, size s: CGFloat, animate: Bool) -> CALayer {
        let eyes = CALayer()
        eyes.frame = CGRect(x: 0, y: 0, width: s, height: s)
        let centerY = s * 0.48 + look.gazeY * s
        let gap = s * 0.2

        switch look.eyes {
        case .open:
            let width = s * 0.13
            let height = s * 0.26 * look.eyeOpenness
            for side in [-1.0, 1.0] {
                let eye = CALayer()
                eye.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                eye.position = CGPoint(x: s / 2 + side * (gap / 2 + width / 2), y: centerY)
                eye.cornerRadius = width / 2
                eye.backgroundColor = Self.eyeColor
                if animate && look.blinks { eye.add(CharacterAnimations.blink(), forKey: "blink") }
                eyes.addSublayer(eye)
            }
        case .happy:
            let width = s * 0.19
            let height = s * 0.1
            for side in [-1.0, 1.0] {
                let arc = CAShapeLayer()
                let path = CGMutablePath()
                // Upward arc (∩) in top-left-origin coordinates.
                path.move(to: CGPoint(x: 0, y: height))
                path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width / 2, y: -height * 0.7))
                arc.path = path
                arc.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                arc.position = CGPoint(x: s / 2 + side * (gap * 0.4 + width / 2), y: centerY - s * 0.02)
                arc.strokeColor = Self.eyeColor
                arc.fillColor = nil
                arc.lineWidth = s * 0.075
                arc.lineCap = .round
                eyes.addSublayer(arc)
            }
        case .sad:
            let width = s * 0.2
            let height = s * 0.07
            for side in [-1.0, 1.0] {
                let eye = CALayer()
                eye.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                eye.position = CGPoint(x: s / 2 + side * (gap / 2 + width / 2), y: centerY)
                eye.cornerRadius = height / 2
                eye.backgroundColor = Self.eyeColor
                // Outer ends droop.
                eye.setAffineTransform(CGAffineTransform(rotationAngle: side * .pi / 10))
                eyes.addSublayer(eye)
            }
        }

        if animate, let period = look.wanderPeriod {
            eyes.add(CharacterAnimations.eyeWander(distance: s * 0.05, period: period), forKey: "wander")
        }
        return eyes
    }

    private func makeBadge(_ badge: CharacterState.Badge, size s: CGFloat, animate: Bool) -> CALayer? {
        let d = max(8, s * 0.42)
        let frame = CGRect(x: s - d * 0.6, y: -d * 0.4, width: d, height: d)
        switch badge {
        case .none:
            return nil
        case .attention, .error:
            let circle = CALayer()
            circle.frame = frame
            circle.cornerRadius = d / 2
            circle.backgroundColor = (badge == .attention ? CharacterState.attentionYellow : CharacterState.errorRed).cgColor
            let mark = textLayer("!", size: d * 0.74, weight: .heavy, color: NSColor.black.withAlphaComponent(0.85))
            mark.frame = CGRect(x: 0, y: (d - d * 0.74 * 1.25) / 2, width: d, height: d * 0.74 * 1.25)
            circle.addSublayer(mark)
            if animate && badge == .attention {
                circle.add(CharacterAnimations.pulse(period: 1.2, amount: 0.1), forKey: "pulse")
            }
            return circle
        case .reply:
            let image = NSImage(systemSymbolName: "ellipsis.bubble.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: d, weight: .bold)
                    .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.92)])))
            let bubble = CALayer()
            bubble.frame = frame
            bubble.contents = image
            bubble.contentsGravity = .resizeAspect
            bubble.contentsScale = scale
            if animate {
                bubble.add(CharacterAnimations.pulse(period: 2.2, amount: 0.08), forKey: "pulse")
            }
            return bubble
        case .done:
            let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: d, weight: .bold)
                    .applying(.init(paletteColors: [CharacterState.doneGreen])))
            let sparkle = CALayer()
            sparkle.frame = frame
            sparkle.contents = image
            sparkle.contentsGravity = .resizeAspect
            sparkle.contentsScale = scale
            return sparkle
        }
    }

    private func makeMark(kind: ProviderKind, size s: CGFloat) -> CALayer {
        let d = s * 0.36
        let circle = CALayer()
        circle.frame = CGRect(x: s - d * 0.7, y: s - d * 0.7, width: d, height: d)
        circle.cornerRadius = d / 2
        circle.backgroundColor = NSColor.black.cgColor
        circle.borderColor = kind.nsAccent.withAlphaComponent(0.6).cgColor
        circle.borderWidth = 1
        let letter = textLayer(kind == .claude ? "C" : "G", size: d * 0.62, weight: .bold, color: kind.nsAccent)
        letter.frame = CGRect(x: 0, y: (d - d * 0.62 * 1.25) / 2, width: d, height: d * 0.62 * 1.25)
        circle.addSublayer(letter)
        return circle
    }

    private func textLayer(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> CATextLayer {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        let layer = CATextLayer()
        layer.string = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        layer.alignmentMode = .center
        layer.contentsScale = scale
        return layer
    }
}

/// The animated "…" after Thinking / Working, also on Core Animation.
struct AnimatedDots: NSViewRepresentable {
    var period: Double = 1.2

    func makeNSView(context: Context) -> DotsLayerView { DotsLayerView() }

    func updateNSView(_ view: DotsLayerView, context: Context) { view.configure(period: period) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsLayerView, context: Context) -> CGSize? {
        CGSize(width: DotsLayerView.width, height: DotsLayerView.dot)
    }
}

final class DotsLayerView: NSView {
    static let dot: CGFloat = 2.5
    static let spacing: CGFloat = 2
    static let width = dot * 3 + spacing * 2
    private var period: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(period: Double) {
        guard period != self.period, let layer else { return }
        self.period = period
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(index) * (Self.dot + Self.spacing), y: 0, width: Self.dot, height: Self.dot)
            dot.cornerRadius = Self.dot / 2
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
            dot.opacity = 0.3
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                dot.add(CharacterAnimations.dot(index: index, period: period), forKey: "dot")
            }
            layer.addSublayer(dot)
        }
    }
}
