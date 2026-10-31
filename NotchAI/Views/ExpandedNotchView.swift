import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Body of the open panel (2026-11-01): the recorder first and big, then Jarvis. Everything else —
/// the sites, Claude and GPT, and on the left the calendar and the desk (music, clipboard, shelf,
/// timer) — appears only when switched on in the `…` menu; the panel is sized to what is on
/// (`AppModel.layout`). 동근님: 「쓰는 건 녹음뿐」.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    /// The panel's own accent is the red from the wallpaper; the agent colours stay on the agents.
    private var accent: Color { NotchPalette.red }
    private var features: NotchFeatures { app.features }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if features.hasLeftColumn {
                VStack(spacing: 8) {
                    if features.isOn(.calendar) {
                        CalendarPane(source: app.schedule, accent: accent)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    if features.isOn(.calendar), !features.deskTabs.isEmpty {
                        Divider().overlay(.white.opacity(0.1))
                    }
                    if !features.deskTabs.isEmpty {
                        DeskView(app: app, accent: accent, onFocusChange: { notch.setKeepsOpen($0) },
                                 tabs: features.deskTabs, showsMenu: false)
                            .frame(height: AppModel.agentsHeight)
                            .frame(maxHeight: features.isOn(.calendar) ? nil : .infinity, alignment: .top)
                    }
                }
                .frame(width: AppModel.leftColumnWidth)
                .frame(maxHeight: .infinity, alignment: .top)

                Divider().overlay(.white.opacity(0.1))
            }

            VStack(alignment: .leading, spacing: AppModel.sectionSpacing) {
                RecordPanel(recorder: app.recorder, accent: accent, large: true,
                            accessory: AnyView(MoreMenu(app: app)))
                    .frame(height: AppModel.recorderHeight, alignment: .top)
                if features.isOn(.launcher) {
                    Divider().overlay(.white.opacity(0.1))
                    SitesPane(launcher: app.launcher)
                        .frame(height: AppModel.launcherHeight, alignment: .top)
                }
                if app.jarvis.isEnabled {
                    Divider().overlay(.white.opacity(0.1))
                    JarvisSection(jarvis: app.jarvis)
                }
                if features.isOn(.agents) {
                    Divider().overlay(.white.opacity(0.1))
                    AgentBadges(providers: app.providers)
                        .frame(height: AppModel.agentsHeight)
                }
            }
            .frame(width: AppModel.mainColumnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppModel.panelPadding.horizontal)
        .padding(.top, AppModel.panelPadding.top)
        .padding(.bottom, AppModel.panelPadding.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if isDropTarget, features.isOn(.shelf) {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(6)
            }
        }
        // Files dropped anywhere on the panel land on the shelf, when the shelf is on.
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            guard features.isOn(.shelf) else { return false }   // the shelf is hidden
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
