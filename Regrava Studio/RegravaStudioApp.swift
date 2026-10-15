import AppKit
import RegravaCore
import SwiftUI

@main
struct RegravaStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Regrava Studio") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Placeholder until the views are rebuilt.
        Group {
            switch model.screen {
            case .recorder:
                Text("Recorder UI pending (docs/ui-spec/recording.md)")
            case .editor(let editor):
                Text("Editor UI pending — \(editor.project.zooms.count) zoom(s)")
            }
        }
        .alert("Regrava Studio", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
