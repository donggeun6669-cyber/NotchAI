import AppKit
import SwiftUI

/// Ribbon Studio desktop colours. The panel meets the hardware in black, then thins into the
/// wallpaper's graphite with one restrained red reflection near the lower edge.
enum NotchPalette {
    /// The red from the wallpaper. Used for what is urgent, and for the desk's own accents.
    nonisolated static let nsRed = NSColor(srgbRed: 0.851, green: 0.176, blue: 0.212, alpha: 1)
    static var red: Color { Color(nsColor: nsRed) }

    /// The plinth in the wallpaper. Used below the hardware-black seam so the glass belongs to
    /// the same scene instead of reading as a separate warm or blue-black overlay.
    nonisolated static let nsGraphite = NSColor(srgbRed: 0.090, green: 0.098, blue: 0.110, alpha: 1)
    static var graphite: Color { Color(nsColor: nsGraphite) }

    /// Panel chrome: borders and fills that should not carry a hue.
    static var hairline: Color { .white.opacity(0.14) }
    static var quiet: Color { .white.opacity(0.48) }
}
