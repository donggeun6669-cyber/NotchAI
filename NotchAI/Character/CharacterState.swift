import AppKit
import SwiftUI

/// How the character looks and moves in each agent state. Pure data; `AICharacterView` turns it
/// into layers and `CharacterAnimations`.
struct CharacterState: Equatable {
    enum Eyes: Equatable {
        case open        // capsules
        case happy       // upward arcs
        case sad         // droopy slanted lines
    }

    /// What the body is doing. Only drawn at sizes big enough to read (the collapsed notch
    /// keeps the plain head).
    enum Pose: Equatable {
        case rest        // arms hanging, slow breath
        case think       // one hand at the chin, head tilted, thought dots
        case work        // arms pumping, sweat flying
        case raiseHand   // one arm up, waving: it needs an answer
        case cheer       // both arms up
        case droop       // arms hanging low, no swing
    }

    enum Badge: Equatable {
        case none
        case attention   // yellow "!"
        case error       // red "!"
        case done        // sparkle
        case reply       // white speech bubble: your turn
    }

    var eyes: Eyes
    var eyeOpenness: CGFloat
    var glowColor: NSColor
    var glowRange: ClosedRange<Float>
    var badge: Badge
    /// Seconds per breath / pulse; lower is faster.
    var pulsePeriod: Double
    var pulseAmount: CGFloat
    /// Vertical gaze: negative looks up, positive looks down (fraction of size).
    var gazeY: CGFloat
    /// Side-to-side eye movement period; nil keeps the eyes still.
    var wanderPeriod: Double?
    var blinks: Bool
    var pose: Pose
    /// Head tilt in radians; the whole body leans.
    var tilt: CGFloat

    static let attentionYellow = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.25, alpha: 1)
    static let errorRed = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)
    static let doneGreen = NSColor(srgbRed: 0.36, green: 0.84, blue: 0.54, alpha: 1)

    init(state: AgentState, accent: NSColor) {
        switch state {
        case .idle:
            self.init(eyes: .open, eyeOpenness: 1, glowColor: accent, glowRange: 0.25...0.45, badge: .none,
                      pulsePeriod: 3.4, pulseAmount: 0.025, gazeY: 0, wanderPeriod: nil, blinks: true,
                      pose: .rest, tilt: 0)
        case .thinking:
            self.init(eyes: .open, eyeOpenness: 1, glowColor: accent, glowRange: 0.4...0.8, badge: .none,
                      pulsePeriod: 1.8, pulseAmount: 0.03, gazeY: -0.04, wanderPeriod: 2.6, blinks: true,
                      pose: .think, tilt: 0.13)
        case .working:
            self.init(eyes: .open, eyeOpenness: 0.8, glowColor: accent, glowRange: 0.5...0.9, badge: .none,
                      pulsePeriod: 0.9, pulseAmount: 0.03, gazeY: 0.03, wanderPeriod: 1.1, blinks: false,
                      pose: .work, tilt: -0.07)
        case .waitingForApproval:
            self.init(eyes: .open, eyeOpenness: 1.2, glowColor: Self.attentionYellow, glowRange: 0.4...0.9,
                      badge: .attention, pulsePeriod: 1.2, pulseAmount: 0.02, gazeY: 0, wanderPeriod: nil,
                      blinks: true, pose: .raiseHand, tilt: 0)
        case .completed:
            self.init(eyes: .happy, eyeOpenness: 1, glowColor: Self.doneGreen, glowRange: 0.5...0.8, badge: .done,
                      pulsePeriod: 3.4, pulseAmount: 0.02, gazeY: 0, wanderPeriod: nil, blinks: false,
                      pose: .cheer, tilt: 0)
        case .awaitingReply:
            // Its own colour (approval is yellow), eyes turned down toward the user, a slow nod.
            self.init(eyes: .open, eyeOpenness: 1.1, glowColor: accent, glowRange: 0.35...0.7, badge: .reply,
                      pulsePeriod: 2.2, pulseAmount: 0.03, gazeY: 0.05, wanderPeriod: nil, blinks: true,
                      pose: .rest, tilt: 0.06)
        case .error:
            self.init(eyes: .sad, eyeOpenness: 1, glowColor: Self.errorRed, glowRange: 0.4...0.6, badge: .error,
                      pulsePeriod: 3.4, pulseAmount: 0.015, gazeY: 0.02, wanderPeriod: nil, blinks: false,
                      pose: .droop, tilt: 0.05)
        }
    }

    init(eyes: Eyes, eyeOpenness: CGFloat, glowColor: NSColor, glowRange: ClosedRange<Float>, badge: Badge,
         pulsePeriod: Double, pulseAmount: CGFloat, gazeY: CGFloat, wanderPeriod: Double?, blinks: Bool,
         pose: Pose = .rest, tilt: CGFloat = 0) {
        self.eyes = eyes
        self.eyeOpenness = eyeOpenness
        self.glowColor = glowColor
        self.glowRange = glowRange
        self.badge = badge
        self.pulsePeriod = pulsePeriod
        self.pulseAmount = pulseAmount
        self.gazeY = gazeY
        self.wanderPeriod = wanderPeriod
        self.blinks = blinks
        self.pose = pose
        self.tilt = tilt
    }
}

extension AgentState {
    /// Color of the status dot next to the label.
    func indicatorColor(accent: Color) -> Color {
        switch self {
        case .idle: .white.opacity(0.4)
        case .thinking, .working: accent
        case .waitingForApproval: Color(nsColor: CharacterState.attentionYellow)
        case .completed: Color(nsColor: CharacterState.doneGreen)
        case .awaitingReply: accent.opacity(0.7)
        case .error: Color(nsColor: CharacterState.errorRed)
        }
    }
}
