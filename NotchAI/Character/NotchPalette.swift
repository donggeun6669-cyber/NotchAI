import AppKit
import SwiftUI

/// The desk's colours. The wallpaper is a light grey studio sweep with one red object, so the
/// panel keeps its chrome neutral and spends colour only where it means something.
enum NotchPalette {
    /// The red from the wallpaper. Used for what is urgent, and for the desk's own accents.
    nonisolated static let nsRed = NSColor(srgbRed: 0.80, green: 0.165, blue: 0.15, alpha: 1)
    static var red: Color { Color(nsColor: nsRed) }

    /// Panel chrome: borders and fills that should not carry a hue.
    static var hairline: Color { .white.opacity(0.12) }
    static var quiet: Color { .white.opacity(0.45) }
}
