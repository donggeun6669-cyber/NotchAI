import SwiftUI
import UniformTypeIdentifiers

/// The open panel, split left and right first (as in NotchAI):
/// left — the calendar with the day's list, and the desk (music, clipboard, shelf, timer) under it;
/// right — the recorder, the places worth one click, and the latest recordings to transcribe.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    private var accent: Color { NotchPalette.red }
    /// The desk and the recordings share this height, so the two bottom rows line up.
    private static let bottomHeight: CGFloat = 58

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                CalendarPane(source: app.calendar, accent: accent)
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
                Divider().overlay(.white.opacity(0.1))
                RecentTakesPane(recorder: app.desk.recorder, transcriber: app.transcriber, accent: accent)
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
        // Files dropped anywhere else on the panel land on the shelf.
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for item in providers {
                    if let data = try? await item.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
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
