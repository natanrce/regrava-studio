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
