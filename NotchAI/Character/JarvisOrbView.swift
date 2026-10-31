import AppKit
import QuartzCore
import SwiftUI

/// What the Jarvis light shows. Worked out from the connection so the drawing never has to guess.
enum JarvisOrbState: Equatable {
    /// Started, no answer yet: a faint empty ring.
    case checking
    /// Desktop or Tailscale unreachable: a grey ring with a slash — no light, no motion, so it can
    /// never be mistaken for resting.
    case offline
    case idle
    case thinking
    /// Satellites circle the light, one per running job (up to `maxSatellites`).
    case working(jobs: Int)
    /// Yellow with "!", like the agents' approval face.
    case needsApproval
    case listening
    case speaking
    /// A state this build does not know: a plain, still light.
    case unknown

    static let maxSatellites = 3

    /// Nil when Jarvis is switched off (no address): nothing is drawn.
    init?(_ connection: JarvisConnection) {
        switch connection {
        case .off: return nil
        case .checking: self = .checking
        case .offline: self = .offline
        case .online(let presence):
            switch presence.shownState {
            case .idle: self = .idle
            case .thinking: self = .thinking
            case .working: self = .working(jobs: min(max(presence.runningJobs, 1), Self.maxSatellites))
            case .needsApproval: self = .needsApproval
            case .listening: self = .listening
            case .speaking: self = .speaking
            case .unknown: self = .unknown
            }
        }
    }
}

/// Jarvis beside the notch: a small light in the same family as the agents' glow (breathing,
/// brighter and faster when busy, yellow when it needs the user), but round and blue, and without
/// a face — it is the one in charge, not another worker. Core Animation, like the characters.
struct JarvisOrbView: NSViewRepresentable {
    let state: JarvisOrbState
    var size: CGFloat = 10

    static let nsBlue = NSColor(srgbRed: 0.40, green: 0.74, blue: 1.0, alpha: 1)
    static var blue: Color { Color(nsColor: nsBlue) }

    func makeNSView(context: Context) -> JarvisOrbLayerView { JarvisOrbLayerView() }

    func updateNSView(_ view: JarvisOrbLayerView, context: Context) {
        view.configure(state: state, size: size)
        view.setAccessibilityLabel("Jarvis")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: JarvisOrbLayerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class JarvisOrbLayerView: NSView {
    private var current: (state: JarvisOrbState, size: CGFloat)?
    private let stage = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let current else { return }
        self.current = nil
        configure(state: current.state, size: current.size)
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func configure(state: JarvisOrbState, size: CGFloat) {
        if let current, current.state == state, current.size == size { return }
        current = (state, size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        let s = size
        stage.frame = CGRect(x: 0, y: 0, width: s, height: s)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let blue = JarvisOrbView.nsBlue
        let yellow = CharacterState.attentionYellow

        switch state {
        case .checking:
            stage.addSublayer(ring(size: s, color: NSColor.white.withAlphaComponent(0.28), slash: false))
        case .offline:
            stage.addSublayer(ring(size: s, color: NSColor.white.withAlphaComponent(0.55), slash: true))
        case .idle:
            stage.addSublayer(glow(size: s, color: blue, range: 0.25...0.45, period: 3.4, animate: animate))
            stage.addSublayer(core(size: s, diameter: s * 0.7, color: blue, pulse: animate ? (3.4, 0.03) : nil))
        case .thinking:
            stage.addSublayer(glow(size: s, color: blue, range: 0.4...0.8, period: 1.8, animate: animate))
            stage.addSublayer(core(size: s, diameter: s * 0.7, color: blue, pulse: animate ? (1.8, 0.07) : nil))
        case .working(let jobs):
            stage.addSublayer(glow(size: s, color: blue, range: 0.5...0.9, period: 0.9, animate: animate))
            stage.addSublayer(core(size: s, diameter: s * 0.5, color: blue, pulse: animate ? (0.9, 0.06) : nil))
            stage.addSublayer(satellites(count: jobs, size: s, color: blue, animate: animate))
        case .needsApproval:
            stage.addSublayer(glow(size: s, color: yellow, range: 0.4...0.9, period: 1.2, animate: animate))
            let dot = core(size: s, diameter: s * 0.92, color: yellow, pulse: animate ? (1.2, 0.08) : nil)
            let mark = textLayer("!", size: s * 0.74)
            mark.frame = CGRect(x: 0, y: (dot.bounds.height - s * 0.74 * 1.25) / 2,
                                width: dot.bounds.width, height: s * 0.74 * 1.25)
            dot.addSublayer(mark)
            stage.addSublayer(dot)
        case .listening:
            stage.addSublayer(glow(size: s, color: blue, range: 0.45...0.8, period: 1.4, animate: animate))
            if animate { stage.addSublayer(ripple(size: s, color: blue)) }
            stage.addSublayer(core(size: s, diameter: s * 0.6, color: blue, pulse: nil))
        case .speaking:
            stage.addSublayer(glow(size: s, color: blue, range: 0.6...1.0, period: 0.4, animate: animate))
            stage.addSublayer(core(size: s, diameter: s * 0.72, color: blue, pulse: animate ? (0.4, 0.14) : nil))
        case .unknown:
            stage.addSublayer(core(size: s, diameter: s * 0.6, color: NSColor.white.withAlphaComponent(0.6), pulse: nil))
        }
    }

    // MARK: Pieces

    private func glow(size s: CGFloat, color: NSColor, range: ClosedRange<Float>, period: Double, animate: Bool) -> CALayer {
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
        glow.locations = [0.25, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: -s * 0.5, y: -s * 0.5, width: s * 2, height: s * 2)
        glow.opacity = range.lowerBound
        if animate {
            glow.add(CharacterAnimations.glow(period: period, from: range.lowerBound, to: range.upperBound), forKey: "glow")
        }
        return glow
    }

    private func core(size s: CGFloat, diameter d: CGFloat, color: NSColor, pulse: (period: Double, amount: CGFloat)?) -> CALayer {
        let core = CALayer()
        core.frame = CGRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)
        core.cornerRadius = d / 2
        core.backgroundColor = color.cgColor
        // A highlight on top, like the characters' bodies.
        let shine = CAGradientLayer()
        shine.frame = core.bounds
        shine.cornerRadius = d / 2
        shine.colors = [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        shine.startPoint = CGPoint(x: 0.5, y: 0)
        shine.endPoint = CGPoint(x: 0.5, y: 0.6)
        core.addSublayer(shine)
        if let pulse { core.add(CharacterAnimations.pulse(period: pulse.period, amount: pulse.amount), forKey: "pulse") }
        return core
    }

    /// Empty ring; with a slash it reads as "no connection".
    private func ring(size s: CGFloat, color: NSColor, slash: Bool) -> CALayer {
        let line = max(1, s * 0.11)
        let inset = line / 2 + s * 0.06
        let rect = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: inset, dy: inset)
        let shape = CAShapeLayer()
        shape.frame = CGRect(x: 0, y: 0, width: s, height: s)
        let path = CGMutablePath()
        path.addEllipse(in: rect)
        if slash {
            let r = rect.width / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let d = r * 0.7071
            path.move(to: CGPoint(x: c.x - d, y: c.y - d))
            path.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
        }
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = line
        shape.lineCap = .round
        return shape
    }

    /// One small dot per running job, circling the light.
    private func satellites(count: Int, size s: CGFloat, color: NSColor, animate: Bool) -> CALayer {
        let orbit = CALayer()
        orbit.frame = CGRect(x: 0, y: 0, width: s, height: s)
        let d = max(1.6, s * 0.2)
        let radius = s * 0.5 - d / 2
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi / 2
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.position = CGPoint(x: s / 2 + cos(angle) * radius, y: s / 2 + sin(angle) * radius)
            dot.cornerRadius = d / 2
            dot.backgroundColor = color.blended(withFraction: 0.45, of: .white)?.cgColor ?? color.cgColor
            orbit.addSublayer(dot)
        }
        if animate {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.6
            spin.repeatCount = .infinity
            orbit.add(spin, forKey: "spin")
        }
        return orbit
    }

    /// A ring growing out of the light and fading, over and over: it is listening.
    private func ripple(size s: CGFloat, color: NSColor) -> CALayer {
        let ring = CALayer()
        ring.frame = CGRect(x: 0, y: 0, width: s, height: s)
        ring.cornerRadius = s / 2
        ring.borderColor = color.cgColor
        ring.borderWidth = max(1, s * 0.08)
        ring.opacity = 0

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.55
        grow.toValue = 1.15
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0]
        fade.keyTimes = [0, 0.2, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ripple")
        return ring
    }

    private func textLayer(_ string: String, size: CGFloat) -> CATextLayer {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        let layer = CATextLayer()
        layer.string = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
        layer.alignmentMode = .center
        layer.contentsScale = scale
        return layer
    }
}
