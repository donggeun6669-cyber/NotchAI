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

    enum Badge: Equatable {
        case none
        case attention   // yellow "!"
        case error       // red "!"
        case done        // sparkle
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

    static let attentionYellow = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.25, alpha: 1)
    static let errorRed = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)
    static let doneGreen = NSColor(srgbRed: 0.36, green: 0.84, blue: 0.54, alpha: 1)

    init(state: AgentState, accent: NSColor) {
        switch state {
        case .idle:
            self.init(eyes: .open, eyeOpenness: 1, glowColor: accent, glowRange: 0.25...0.45, badge: .none,
                      pulsePeriod: 3.4, pulseAmount: 0.025, gazeY: 0, wanderPeriod: nil, blinks: true)
        case .thinking:
            self.init(eyes: .open, eyeOpenness: 1, glowColor: accent, glowRange: 0.4...0.8, badge: .none,
                      pulsePeriod: 1.8, pulseAmount: 0.03, gazeY: -0.04, wanderPeriod: 2.6, blinks: true)
        case .working:
            self.init(eyes: .open, eyeOpenness: 0.8, glowColor: accent, glowRange: 0.5...0.9, badge: .none,
                      pulsePeriod: 0.9, pulseAmount: 0.03, gazeY: 0.03, wanderPeriod: 1.1, blinks: false)
        case .waitingForApproval:
            self.init(eyes: .open, eyeOpenness: 1.2, glowColor: Self.attentionYellow, glowRange: 0.4...0.9,
                      badge: .attention, pulsePeriod: 1.2, pulseAmount: 0.02, gazeY: 0, wanderPeriod: nil, blinks: true)
        case .completed:
            self.init(eyes: .happy, eyeOpenness: 1, glowColor: Self.doneGreen, glowRange: 0.5...0.8, badge: .done,
                      pulsePeriod: 3.4, pulseAmount: 0.02, gazeY: 0, wanderPeriod: nil, blinks: false)
        case .error:
            self.init(eyes: .sad, eyeOpenness: 1, glowColor: Self.errorRed, glowRange: 0.4...0.6, badge: .error,
                      pulsePeriod: 3.4, pulseAmount: 0.015, gazeY: 0.02, wanderPeriod: nil, blinks: false)
        }
    }

    init(eyes: Eyes, eyeOpenness: CGFloat, glowColor: NSColor, glowRange: ClosedRange<Float>, badge: Badge,
         pulsePeriod: Double, pulseAmount: CGFloat, gazeY: CGFloat, wanderPeriod: Double?, blinks: Bool) {
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
        case .error: Color(nsColor: CharacterState.errorRed)
        }
    }
}
