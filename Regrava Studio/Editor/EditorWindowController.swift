import AVFoundation
import AppKit
import RegravaCore
import SwiftUI

/// One window per project (the editor UI itself is built next).
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel

    init(bundleURL: URL, project: Project) {
        model = EditorModel(bundleURL: bundleURL, project: project)
        let hosting = NSHostingController(rootView: EditorPlaceholder(editor: model))
        // Fixed window size; don't let the SwiftUI content resize the window.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = model.projectName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.Colors.background)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        super.init(window: window)
        window.delegate = self
        Task { await model.prepare() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
        model.player.pause()
        AppController.shared.editorClosed(self)
    }
}

/// Temporary editor host so export can be used before the editor UI lands.
struct EditorPlaceholder: View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .foregroundStyle(Theme.Colors.text)
    }
}
