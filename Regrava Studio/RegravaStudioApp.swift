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
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Export...") {
                    if case .editor(let editor) = model.screen { editor.openExportPicker() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app has a dark-only theme.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if UISnapshots.runIfRequested() { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Recorder and editor views are rebuilt next; placeholders for now.
        Group {
            switch model.screen {
            case .recorder:
                Text("Recorder UI pending (docs/ui-spec/recording.md)")
            case .editor(let editor):
                EditorPlaceholder(editor: editor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
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

/// Temporary editor host so export can be used before the editor UI lands.
private struct EditorPlaceholder: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var exports: ExportController

    init(editor: EditorModel) {
        self.editor = editor
        exports = editor.exports
    }

    var body: some View {
        ZStack {
            VStack(spacing: Theme.gap(2)) {
                Text("Editor UI pending — \(editor.project.zooms.count) zoom(s)")
                RSButton(title: "Export", kind: .primary) { editor.openExportPicker() }
                    .disabled(exports.isExporting)
                    .help(exports.isExporting ? "Only one export can be active at a time" : "")
            }
            if exports.isPickerOpen {
                ExportPickerOverlay(
                    exports: exports,
                    project: editor.project,
                    projectName: editor.projectName,
                    videoURL: editor.videoURL
                )
            }
            if exports.isExporting {
                ExportStatusOverlay(exports: exports)
            }
        }
    }
}
