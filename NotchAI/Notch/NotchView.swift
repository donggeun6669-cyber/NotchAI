import SwiftUI

/// Root view. Fills the fixed-size window and draws the black notch extension at the top center,
/// sized to the current state.
struct NotchView: View {
    let model: NotchViewModel
    let app: AppModel

    private var geometry: NotchGeometry { model.geometry }

    var body: some View {
        let size = model.currentSize
        // The island floats, so it has no ears growing out of the screen edge.
        let ear = geometry.isIsland ? 0 : NotchGeometry.earRadius
        let compact = !model.isExpanded && model.isCompact()

        ZStack(alignment: .top) {
            Group {
                if geometry.isIsland {
                    // Dynamic Island: a capsule when collapsed, a rounded panel when open.
                    let island = RoundedRectangle(cornerRadius: model.isExpanded ? 24 : size.height / 2,
                                                  style: .continuous)
                    NotchBackdrop(shape: island, solidHeight: geometry.notchHeight,
                                  isExpanded: model.isExpanded)
                } else {
                    NotchBackdrop(shape: NotchShape(earRadius: ear, bottomRadius: model.isExpanded ? 22 : 10),
                                  solidHeight: geometry.notchHeight, isExpanded: model.isExpanded)
                }
            }
            .frame(width: size.width + ear * 2, height: size.height)
            .shadow(color: .black.opacity(geometry.isIsland ? 0.5 : (model.isExpanded ? 0.4 : 0)),
                    radius: geometry.isIsland ? 12 : 14, y: geometry.isIsland ? 4 : 6)

            VStack(spacing: 0) {
                // The open panel keeps the same strip on top, so a running clock stays in place.
                let narrow = model.isCompact()
                CollapsedNotchView(app: app, notchWidth: geometry.notchRect.width, height: geometry.notchHeight,
                                   wingWidth: narrow ? geometry.layout.narrowWing : geometry.layout.wideWing,
                                   narrow: narrow)
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
        .onChange(of: model.isExpanded) { _, open in
            guard open else { return }
            // The job list and the conversation should be fresh when they are seen.
            app.jarvis.wantJobs()
            Task { await app.chat.open() }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.isExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: compact)
        .frame(width: geometry.windowFrame.width, height: geometry.windowFrame.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
