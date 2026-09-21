import SwiftUI

/// Root view. Fills the fixed-size window and draws the black notch extension at the top center,
/// sized to the current state.
struct NotchView: View {
    let model: NotchViewModel
    let app: AppModel

    private var geometry: NotchGeometry { model.geometry }

    var body: some View {
        let size = model.currentSize
        let ear = NotchGeometry.earRadius
        let compact = !model.isExpanded && model.isCompact()

        ZStack(alignment: .top) {
            NotchShape(earRadius: ear, bottomRadius: model.isExpanded ? 22 : 10)
                .fill(.black)
                .frame(width: size.width + ear * 2, height: size.height)
                .shadow(color: .black.opacity(model.isExpanded ? 0.4 : 0), radius: 14, y: 6)

            VStack(spacing: 0) {
                CollapsedNotchView(left: app.provider(.claude), right: app.provider(.gpt),
                                   track: app.desk.peekingTrack,
                                   notchWidth: geometry.notchRect.width, height: geometry.notchHeight,
                                   compact: compact)
                if model.isExpanded {
                    ExpandedNotchView(app: app, notch: model)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + ear * 2, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture { model.expand() }
        .contextMenu {
            Button("Quit NotchAI") { NSApp.terminate(nil) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.isExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: compact)
        .frame(width: geometry.windowFrame.width, height: geometry.windowFrame.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Flat top that meets the screen edge with small outward curves (so it reads as part of the
/// hardware notch), straight sides, rounded bottom corners.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ear = earRadius
        let bottom = min(bottomRadius, rect.height / 2, (rect.width - ear * 2) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                          control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
