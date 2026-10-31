import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Body of the open panel (2026-11-01). Left, where the calendar was: Jarvis — its jobs and a
/// conversation with it (「캘린더 있던 칸 전체에 Jarvis 넣어도 돼」). Right: the recorder, compact
/// (「녹음은 있기만 하면 돼」), and the sites (「자주 가는 사이트 정도는 써」). The calendar, the desk
/// (music, clipboard, shelf, timer) and Claude and GPT appear only when switched on in the `…`
/// menu: the calendar shares the left with Jarvis behind two tabs, the desk sits under them, the
/// characters under the sites.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false
    @AppStorage("leftShowsCalendar") private var leftShowsCalendar = false

    /// The panel's own accent is the red from the wallpaper; the agent colours stay on the agents.
    private var accent: Color { NotchPalette.red }
    private var features: NotchFeatures { app.features }

    private var hasLeft: Bool { app.jarvis.isEnabled || features.hasLeftColumn }
    private var showsCalendar: Bool {
        features.isOn(.calendar) && (!app.jarvis.isEnabled || leftShowsCalendar)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if hasLeft {
                VStack(alignment: .leading, spacing: 8) {
                    if app.jarvis.isEnabled, features.isOn(.calendar) { leftTabs }
                    if showsCalendar {
                        CalendarPane(source: app.schedule, accent: accent)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else if app.jarvis.isEnabled {
                        JarvisPane(jarvis: app.jarvis, chat: app.chat, approvals: app.approvals,
                                   onFocusChange: { notch.setKeepsOpen($0) })
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if !features.deskTabs.isEmpty {
                        Divider().overlay(.white.opacity(0.1))
                        DeskView(app: app, accent: accent, onFocusChange: { notch.setKeepsOpen($0) },
                                 tabs: features.deskTabs, showsMenu: false)
                            .frame(height: AppModel.agentsHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Divider().overlay(.white.opacity(0.1))
            }

            VStack(alignment: .leading, spacing: AppModel.sectionSpacing) {
                RecordPanel(recorder: app.recorder, accent: accent, accessory: AnyView(MoreMenu(app: app)))
                if features.isOn(.launcher) {
                    Divider().overlay(.white.opacity(0.1))
                    SitesPane(launcher: app.launcher)
                        .frame(maxHeight: hasLeft ? .infinity : AppModel.launcherHeight, alignment: .top)
                }
                if hasLeft { Spacer(minLength: 0) }
                if features.isOn(.agents) {
                    AgentBadges(providers: app.providers)
                        .frame(height: AppModel.agentsHeight)
                }
            }
            .frame(width: AppModel.rightColumnWidth)
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

    /// Jarvis and the calendar take turns on the left when both are on.
    private var leftTabs: some View {
        HStack(spacing: 2) {
            tab("Jarvis", selected: !leftShowsCalendar) { leftShowsCalendar = false }
            tab("달력", selected: leftShowsCalendar) { leftShowsCalendar = true }
            Spacer(minLength: 0)
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.45))
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(Capsule().fill(.white.opacity(selected ? 0.13 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
