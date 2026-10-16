import AppKit
import RegravaCore
import SwiftUI

/// Debug aid: `Regrava Studio --render-ui <dir>` renders key screens offscreen to PNG files
/// and quits, so layouts can be checked without screen capture.
@MainActor
enum UISnapshots {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-ui"), index + 1 < args.count else { return false }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.main.async {
            render(to: directory)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func render(to directory: URL) {
        for tab in SettingsTab.allCases {
            let state = SettingsState()
            state.tab = tab
            write(SettingsView(state: state), width: 840, height: nil, to: directory.appendingPathComponent("settings-\(tab.rawValue).png"))
        }

        let project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 3024, height: 1964), pointPixelScale: 2, durationMs: 42_000, fps: 60),
            mouseEvents: []
        )
        let exports = ExportController()
        for format in ExportFormat.allCases {
            Preferences.shared.exportSettings.select(format: format)
            let view = ExportPickerOverlay(
                exports: exports,
                project: project,
                projectName: "Demo",
                videoURL: URL(fileURLWithPath: "/dev/null")
            )
            write(view, width: 1200, height: 900, to: directory.appendingPathComponent("export-picker-\(format.rawValue).png"))
        }
        Preferences.shared.exportSettings.select(format: .mp4)

        // Recording flow. Panels use a HUD material that does not render offscreen, so the
        // content is drawn on a dark backdrop instead.
        let coordinator = RecordingCoordinator()
        coordinator.refreshDevices()
        func onBackdrop<V: View>(_ view: V) -> some View {
            view.background(Color(hex: 0x2A2A2E)).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        write(onBackdrop(RecordingPickerView(coordinator: coordinator)).fixedSize(), width: 1100, height: 64, to: directory.appendingPathComponent("recording-picker.png"))
        write(onBackdrop(RecordingWidgetView(coordinator: coordinator).frame(width: 300)), width: 300, height: 48, to: directory.appendingPathComponent("recording-widget.png"))
        write(StartRecordingButton(coordinator: coordinator).padding(20).background(Color.black.opacity(0.6)), width: 280, height: 90, to: directory.appendingPathComponent("start-button.png"))

        // Onboarding through its real window controller, so the window size is checked too.
        if let window = OnboardingWindowController.shared.window, let view = window.contentView {
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let size = window.frame.size
            try? "\(Int(size.width))x\(Int(size.height))\n".write(to: directory.appendingPathComponent("onboarding-window-size.txt"), atomically: true, encoding: .utf8)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("onboarding.png"))
            }
            window.orderOut(nil)
        }

        renderEditor(to: directory)
    }

    /// The real editor window with a demo project (no video: the preview stays empty).
    private static func renderEditor(to directory: URL) {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Snapshot Demo.\(ProjectStore.fileExtension)")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let clicks = [3000.0, 5200, 14000, 26000, 31000].map { MouseEvent(kind: .down, timeMs: $0, position: Vec2(800, 500)) }
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 3024, height: 1964), pointPixelScale: 2, durationMs: 42_000, fps: 60),
            mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(100, 100))] + clicks,
            markersMs: [9000, 20000]
        )
        project.regenerateAutomaticZooms()
        let controller = EditorWindowController(bundleURL: bundle, project: project)
        guard let window = controller.window, let view = window.contentView else { return }
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1440, height: 860), display: true)
        window.orderFrontRegardless()
        let states: [(String, () -> Void)] = [
            ("general", { controller.model.openSidebar(.background) }),
            ("cursor", { controller.model.openSidebar(.cursor) }),
            ("animations", { controller.model.openSidebar(.animation) }),
            ("zoom", { if let first = controller.model.project.zooms.first { controller.model.openZoom(first.id) } }),
        ]
        for (name, apply) in states {
            apply()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("editor-\(name).png"))
            }
        }
        controller.window?.delegate = nil
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: bundle)
    }

    private static func write<V: View>(_ view: V, width: CGFloat, height: CGFloat?, to url: URL) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: height ?? hosting.fittingSize.height)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
