import AppKit
import SwiftUI

/// The panel's surface. The top has to be the same black as the hardware notch — anything
/// lighter up there makes the notch itself stand out as a dark blob — so the panel starts at
/// pure black and only thins out as it gets further down, away from the notch.
struct NotchBackdrop<S: Shape>: View {
    let shape: S
    /// Height of the strip level with the notch. It stays solid black.
    let solidHeight: CGFloat
    let isExpanded: Bool

    /// How much of the desktop shows through at the very bottom. The graphite stays substantial
    /// enough for white text while the blur and wallpaper lighting still read through it.
    private static var farOpacity: Double { 0.62 }

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let solid = min(0.9, solidHeight / height)

            ZStack {
                // Collapsed, the strip is level with the notch and stays solid; there is nothing
                // to see through anyway.
                if isExpanded { FrostedBackdrop() }

                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: solid),
                    .init(color: isExpanded ? NotchPalette.graphite.opacity(0.90) : .black,
                          location: solid + (1 - solid) * 0.35),
                    .init(color: isExpanded ? NotchPalette.graphite.opacity(Self.farOpacity) : .black,
                          location: 1),
                ], startPoint: .top, endPoint: .bottom)

                // A soft sheen low down, where the surface has already thinned: glass catching
                // light. Never near the top, which must stay as black as the notch.
                if isExpanded {
                    RadialGradient(colors: [.white.opacity(0.06), .clear],
                                   center: UnitPoint(x: 0.22, y: 0.78), startRadius: 0,
                                   endRadius: height * 0.75)
                        .blendMode(.plusLighter)

                    // The wallpaper's red ribbon reflected very faintly in the lower-right
                    // glass. It is deliberately weaker than any status colour.
                    RadialGradient(colors: [NotchPalette.red.opacity(0.08), .clear],
                                   center: UnitPoint(x: 0.82, y: 0.92), startRadius: 0,
                                   endRadius: height * 0.68)
                        .blendMode(.plusLighter)
                }
            }
            .clipShape(shape)
            // The glass edge only appears where the surface has thinned out; at the top it would
            // draw a bright line right against the notch.
            .overlay {
                shape.stroke(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: solid),
                        .init(color: .white.opacity(isExpanded ? 0.14 : 0), location: 1),
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8)
            }
        }
    }
}

/// `NSVisualEffectView` blurring whatever is behind the window.
private struct FrostedBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
