import AppKit
import Observation
import SwiftUI

/// "강의녹음": the lecture recorder from NotchAI on its own, for Macs without a notch or without
/// the rest of NotchAI. It lives in the menu bar and shares RecorderService, AudioDevices and
/// RecordingCheck with NotchAI, so a fix to recording lands in both apps.
@main
struct LectureRecorderApp: App {
    @State private var model = RecorderModel()

    var body: some Scene {
        MenuBarExtra {
            RecorderPanel(recorder: model.recorder)
        } label: {
            MenuBarLabel(recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the recorder's clock, level and silence checks moving while the panel is closed.
@MainActor
@Observable
final class RecorderModel {
    let recorder = RecorderService()
    @ObservationIgnored private var timer: Timer?
    /// `--preview` shows the panel in an ordinary window, for screenshots.
    @ObservationIgnored private var previewWindow: NSWindow?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recorder.poll() }
        }
        if CommandLine.arguments.contains("--preview") {
            // After launch: building a hosting window while SwiftUI is still creating the scene
            // aborts inside the view graph.
            DispatchQueue.main.async { [self] in
                let window = NSWindow(contentViewController: NSHostingController(rootView: RecorderPanel(recorder: recorder)))
                window.title = "강의녹음"
                window.center()
                window.makeKeyAndOrderFront(nil)
                previewWindow = window
            }
        }
    }
}

private struct MenuBarLabel: View {
    let recorder: RecorderService

    var body: some View {
        if recorder.isRunning {
            HStack(spacing: 3) {
                Image(systemName: recorder.silenceAlarm ? "exclamationmark.circle.fill" : "record.circle.fill")
                Text(RecorderService.clock(Int(recorder.elapsed)))
                    .monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}
