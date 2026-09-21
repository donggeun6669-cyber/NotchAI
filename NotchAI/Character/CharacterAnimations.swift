import QuartzCore

/// Core Animation recipes for the character. These run in the window server, so an always-visible,
/// always-breathing character costs the app almost no CPU (a SwiftUI TimelineView re-rendered the
/// whole panel on every frame and used ~5% CPU).
enum CharacterAnimations {
    /// Breathing / pulsing scale, forever.
    static func pulse(period: Double, amount: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1 - amount
        animation.toValue = 1 + amount
        return forever(animation, halfPeriod: period / 2)
    }

    /// Glow brightening and dimming with the pulse.
    static func glow(period: Double, from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        return forever(animation, halfPeriod: period / 2)
    }

    /// A quick blink every few seconds.
    static func blink(every interval: Double = 4.3, duration: Double = 0.16) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        let closeAt = 1 - duration / interval
        animation.values = [1, 1, 0.1, 1]
        animation.keyTimes = [0, NSNumber(value: closeAt), NSNumber(value: closeAt + duration / interval / 2), 1]
        animation.duration = interval
        animation.repeatCount = .infinity
        return animation
    }

    /// Eyes drifting side to side: slow wander while thinking, quick scanning while working.
    static func eyeWander(distance: CGFloat, period: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -distance
        animation.toValue = distance
        return forever(animation, halfPeriod: period / 2)
    }

    /// One soft hop after completing.
    static func hop(height: CGFloat) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, -height, 0, -height * 0.3, 0]
        animation.keyTimes = [0, 0.35, 0.65, 0.82, 1]
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    /// A short headshake after an error.
    static func shake(distance: CGFloat) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -distance, distance, -distance * 0.6, distance * 0.3, 0]
        animation.duration = 0.45
        return animation
    }

    /// An arm swinging around its shoulder. `base` is the resting angle, and the two arms are
    /// given opposite phases so the character looks like it is working, not flapping.
    static func armSwing(base: CGFloat, amount: CGFloat, period: Double, phase: Double = 0) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = base - amount
        animation.toValue = base + amount
        let swing = forever(animation, halfPeriod: period / 2)
        if phase != 0 { swing.timeOffset = period * phase }
        return swing
    }

    /// A drop of sweat: appears at the head, slides away, fades out, over and over.
    static func sweat(distance: CGFloat, period: Double, delay: Double) -> CAAnimationGroup {
        let fall = CAKeyframeAnimation(keyPath: "transform.translation")
        fall.values = [CGPoint.zero,
                       CGPoint(x: distance * 0.45, y: -distance * 0.35),
                       CGPoint(x: distance, y: distance * 0.55)].map { NSValue(point: $0) }
        fall.keyTimes = [0, 0.35, 1]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.9, 0]
        fade.keyTimes = [0, 0.2, 0.6, 1]

        let group = CAAnimationGroup()
        group.animations = [fall, fade]
        group.duration = period
        group.repeatCount = .infinity
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }

    /// One bubble of the thought cloud: swells into view, drifts up, fades.
    static func thought(index: Int, period: Double, rise: CGFloat) -> CAAnimationGroup {
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = rise
        move.toValue = -rise * 0.3

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.95, 0.95, 0]
        fade.keyTimes = [0, 0.25, 0.7, 1]

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = period
        group.repeatCount = .infinity
        group.beginTime = CACurrentMediaTime() + period / 3 * Double(index)
        group.fillMode = .backwards
        return group
    }

    /// A slow lean back and forth, for standing around.
    static func sway(angle: CGFloat, period: Double, base: CGFloat = 0) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = base - angle
        animation.toValue = base + angle
        return forever(animation, halfPeriod: period / 2)
    }

    /// One dot of the "…" indicator; dots are staggered by `index`.
    static func dot(index: Int, period: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.3, 1, 0.3, 0.3]
        animation.keyTimes = [0, 0.2, 0.45, 1]
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + period / 3 * Double(index)
        animation.fillMode = .backwards
        return animation
    }

    private static func forever(_ animation: CABasicAnimation, halfPeriod: Double) -> CABasicAnimation {
        animation.duration = halfPeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}
