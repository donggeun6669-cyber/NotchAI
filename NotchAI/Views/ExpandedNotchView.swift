import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Weekly DEAN board and live Jarvis status share one panel.
struct ExpandedNotchView: View {
    @Bindable var app: AppModel
    let notch: NotchViewModel

    @State private var isDropTarget = false

    /// The panel's own accent is the red from the wallpaper; the agent colours stay on the agents.
    private var accent: Color { NotchPalette.red }
    private var features: NotchFeatures { app.features }

    private var hasLeft: Bool { app.jarvis.isEnabled || features.hasLeftColumn }
    var body: some View {
        VStack(spacing: MonitorStrip.gap) {
            columns
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // CPU · temperature · memory · network under everything else (2026-11-09).
            if features.isOn(.monitor) {
                Divider().overlay(.white.opacity(0.1))
                MonitorStrip(monitor: app.monitor, stacked: !hasLeft)
            }
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

    /// Jarvis (or the calendar) on the left, the recorder and the sites on the right.
    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            if hasLeft {
                VStack(alignment: .leading, spacing: 8) {
                    if app.jarvis.isEnabled || features.isOn(.calendar) {
                        WeeklyBoardPane()
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
                if app.jarvis.isEnabled {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Jarvis").font(.headline)
                            Spacer()
                            Text(JarvisPane.stateLine(app.jarvis.connection))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let room = app.jarvis.workroom {
                            Text("진행  \(room.active)     검토  \(room.review)     완료  \(room.done)")
                                .monospacedDigit().font(.caption)
                            Button { app.jarvis.openApp() } label: {
                                Label(room.handoff?.status == "done" ? "\(room.handoff?.project ?? "최근") 결과 열기" : "작업실 열기",
                                      systemImage:"arrow.up.right.square")
                            }.buttonStyle(.plain).font(.caption.weight(.semibold))
                        } else {
                            Button("작업실 열기") { app.jarvis.openApp() }.buttonStyle(.plain).font(.caption)
                        }
                    }
                    Divider().overlay(.white.opacity(0.1))
                }
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
    }

}

struct WeeklyBoardPane: View {
    @State private var home = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("주간 일정").font(.headline)
                Spacer()
                Button("이번 주") { home += 1 }.buttonStyle(.plain).font(.caption)
                Button { if let url = WeeklyBoardWeb.boardURL { NSWorkspace.shared.open(url) } }
                  label: { Image(systemName:"arrow.up.right.square") }
                  .buttonStyle(.plain).accessibilityLabel("전체 상황판 열기")
            }
            WeeklyBoardWeb(home:home)
                .clipShape(RoundedRectangle(cornerRadius:7))
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
}

struct WeeklyBoardWeb: NSViewRepresentable {
    let home: Int
    static var boardURL: URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/DEAN/01_ASSISTANT")
        let urls = (try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? []
        return urls.filter { $0.lastPathComponent.precomposedStringWithCanonicalMapping
            .range(of: #"^20\d{2}-[12]_학기_상황판\.html$"#, options:.regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var home: Int?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static let adapt = #"""
    (() => {
      const cal=document.querySelector('#flow #cal');
      if(!cal){document.body.textContent='주간 달력을 찾을 수 없습니다.';return;}
      cal.querySelector('.pastbar button[aria-expanded="false"]')?.click();
      const weekList=[...cal.querySelectorAll('.week')];
      if(!weekList.length){document.body.textContent='표시할 학기 일정이 없습니다.';return;}
      const start=weekList.find(w=>w.querySelector('.bg.today')) || weekList.find(w=>w.querySelector('.bg:not(.past)')) || weekList.at(-1);
      document.documentElement.dataset.theme='dark';
      const root=document.createElement('div'); root.id='flow';
      const range=document.createElement('div');range.className='range';root.append(range);
      const head=cal.querySelector('.dow');root.append(head);
      const scroll=document.createElement('div');scroll.id='weeks';scroll.setAttribute('aria-label','학기 주간 일정');
      scroll.tabIndex=0;root.append(scroll);weekList.forEach(w=>scroll.append(w));
      document.body.replaceChildren(root);
      const css=document.createElement('style');css.textContent=`
      :root{color-scheme:dark}html,body{margin:0!important;padding:0!important;width:100%;height:100%;overflow:hidden;background:var(--card)}
      #flow{padding:0!important;margin:0!important;max-width:none!important;height:100%;display:flex;flex-direction:column}
      #flow .dow{flex:none;background:var(--card)}#flow .dow div{padding:4px 3px;text-align:center;font:600 10px -apple-system,sans-serif}
      #weeks{overflow:auto;flex:1;min-height:0;scroll-snap-type:y proximity;overscroll-behavior:contain}
      #flow .week{box-sizing:border-box;min-height:100%;align-content:start;scroll-snap-align:start;background:var(--card)}
      #flow .range{font:600 13px -apple-system,sans-serif;padding:8px 8px 5px;color:var(--ink)}
      #flow .past-dim{opacity:.84}#flow .bg{min-height:100%}#flow .num{padding:4px 3px;font:600 13px -apple-system,sans-serif;gap:2px}
      #flow .num .tag{font-size:8px;padding:0 2px}#flow .cell{padding:1px 2px;min-width:0}
      #flow .ev{font:500 10px/1.3 -apple-system,sans-serif;overflow-wrap:anywhere}#flow .bar{font:600 10px/16px -apple-system,sans-serif;padding:0 3px}
      `;document.head.append(css);
      const current=weekList.findIndex(w=>w.querySelector('.bg.today'));
      const firstDate = new Date();firstDate.setDate(firstDate.getDate()-firstDate.getDay()-current*7);
      function label(){
        const i=weekList.findLastIndex(w=>w.offsetTop-weekList[0].offsetTop<=scroll.scrollTop+3);
        if(current<0){range.textContent='학기 일정';return;}
        const day=new Date(firstDate);day.setDate(day.getDate()+Math.max(0,i)*7);
        const end=new Date(day);end.setDate(end.getDate()+6);
        const dateText=d=>(d.getMonth()+1)+'월 '+d.getDate()+'일';
        range.textContent=dateText(day)+' – '+dateText(end)+(i===current?'  ·  이번 주':'');
      }
      scroll.addEventListener('scroll',label,{passive:true});
      window.jarvisCurrentWeek=()=>{scroll.scrollTop=start.offsetTop-weekList[0].offsetTop;label()};
      requestAnimationFrame(()=>requestAnimationFrame(window.jarvisCurrentWeek));
    })()
    """#
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source:Self.adapt,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        let web = WKWebView(frame:.zero,configuration:config)
        web.navigationDelegate = context.coordinator
        let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">"#
        if let url = Self.boardURL, let html = try? String(contentsOf:url,encoding:.utf8) {
            web.loadHTMLString(policy + html,baseURL:nil)
        } else {
            web.loadHTMLString("<p>DEAN 상황판 파일이 없습니다.</p>",baseURL:nil)
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        if let last=context.coordinator.home, last != home {
            web.evaluateJavaScript("window.jarvisCurrentWeek?.()")
        }
        context.coordinator.home=home
    }
}
