import Foundation
import Observation

/// Providers, the desk (music / clipboard / shelf / Chrome), and which provider the notch shows.
@MainActor
@Observable
final class AppModel {
    let providers: [any AIProvider]
    let desk = DeskModel()

    var selectedKind: ProviderKind {
        didSet { UserDefaults.standard.set(selectedKind.rawValue, forKey: "provider") }
    }

    var selected: any AIProvider {
        providers.first { $0.kind == selectedKind } ?? providers[0]
    }

    @ObservationIgnored private var pollTimer: Timer?

    init(providers: [any AIProvider] = [ClaudeProvider(), GPTProvider()]) {
        self.providers = providers
        selectedKind = UserDefaults.standard.string(forKey: "provider").flatMap(ProviderKind.init) ?? .claude
    }

    func start() {
        providers.forEach { $0.start() }
        pollAll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
    }

    /// Sends a command to the selected provider, with the Chrome page attached if asked for.
    func send(_ prompt: String) {
        selected.sendPrompt(desk.chrome.decorate(prompt))
    }

    private func pollAll() {
        providers.forEach { $0.poll() }
        desk.poll()
    }
}
