import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Body of the expanded panel (2026-10-19), split left and right first:
/// left — the calendar with today's list, and the desk (music, clipboard, shelf, timer) under it;
/// right — the recorder, the sites worth one click, and Claude and GPT as two big characters.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    /// The panel's own accent is the red from the wallpaper; the agent colours stay on the agents.
    private var accent: Color { NotchPalette.red }
    /// The desk and the agent badges share this height, so the two bottom rows line up.
    private static let bottomHeight: CGFloat = 58

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                CalendarPane(source: app.schedule, accent: accent)
                    .frame(maxHeight: .infinity, alignment: .top)
                Divider().overlay(.white.opacity(0.1))
                DeskView(app: app, accent: accent, onFocusChange: { notch.setKeepsOpen($0) })
                    .frame(height: Self.bottomHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 8) {
                RecordPanel(recorder: app.desk.recorder, accent: accent)
                Divider().overlay(.white.opacity(0.1))
                SitesPane(launcher: app.launcher)
                    .frame(maxHeight: .infinity, alignment: .top)
                AgentBadges(providers: app.providers)
                    .frame(height: Self.bottomHeight)
            }
            .frame(width: 236)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(6)
            }
        }
        // Files dropped anywhere on the panel land on the shelf.
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for item in providers {
                    if let url = try? await item.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let decoded = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(decoded)
                    }
                }
                guard !urls.isEmpty else { return }
                app.desk.shelf.add(urls)
                app.desk.tab = .shelf
            }
            return true
        }
    }

}
