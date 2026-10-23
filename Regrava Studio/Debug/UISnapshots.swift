import AppKit
import RegravaCore
import RegravaRender
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
        // Wallpaper library as seen from the app bundle.
        let library = WallpaperLibrary.categories.map { "\($0.name): \($0.wallpapers.count)" }.joined(separator: "\n")
        let resolved = WallpaperLibrary.url(for: BackgroundConfig.defaultWallpaper) != nil
        try? "\(library)\ndefault resolves: \(resolved)\n".write(to: directory.appendingPathComponent("wallpapers.txt"), atomically: true, encoding: .utf8)

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
        write(SpeakerNotesView(store: .shared).environment(\.colorScheme, .dark).background(Color(hex: 0x1C1C1E)), width: 240, height: 320, to: directory.appendingPathComponent("speaker-notes.png"))
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

        // Recent projects strip, with this Mac's recent list.
        let recents = RecentProjectsModel()
        recents.reload()
        write(RecentProjectsView(model: recents, close: {}).background(Color(hex: 0x1C1D22)).environment(\.colorScheme, .dark), width: 1440, height: 280, to: directory.appendingPathComponent("recent-projects.png"))

        // Context menu rows with custom views (palette, slider).
        let menu = NativeContextMenu.build([
            [.palette([
                .init(title: "Classic", icon: "arrow.up.left.and.down.right.magnifyingglass", isSelected: true) {},
                .init(title: "Loupe", icon: "sparkle.magnifyingglass", isSelected: false) {},
            ])],
            [.slider(title: "Zoom level", value: 2.4, range: 1...4, valueLabel: { "\(Int(($0 * 100).rounded()))%" }) { _ in }],
            [.toggle(title: "Show this shortcut", isOn: true) { _ in }],
        ])
        for (index, item) in menu.items.enumerated() {
            guard let view = item.view else { continue }
            view.appearance = NSAppearance(named: .darkAqua)
            let host = NSView(frame: view.frame)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
            host.appearance = NSAppearance(named: .darkAqua)
            host.addSubview(view)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menu-row-\(index).png"))
            }
        }

        // Tooltip bubbles in each placement.
        let bubbles = VStack(spacing: 16) {
            TooltipBubble(config: TooltipConfig(label: "General", placement: .left))
            TooltipBubble(config: TooltipConfig(label: "Classic zoom", placement: .right))
            TooltipBubble(config: TooltipConfig(label: "Go to first frame", shortcut: "⌘←", placement: .top))
        }
        .padding(20)
        .background(Color.black)
        write(bubbles, width: 320, height: 200, to: directory.appendingPathComponent("tooltips.png"))

        renderEditor(to: directory)
    }

    /// The real editor window with a demo project (no video: the preview stays empty).
    private static func renderEditor(to directory: URL) {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Snapshot Demo.\(ProjectStore.fileExtension)")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let clicks = [3000.0, 5200, 14000, 26000, 31000].map { MouseEvent(kind: .down, timeMs: $0, position: Vec2(800, 500)) }
        // A typing run (fast keys 16–19 s) shows a "Speed up typing" chip.
        var keys = stride(from: 16_000.0, through: 19_000, by: 150).flatMap {
            [Keystroke(kind: .down, timeMs: $0, character: "a"), Keystroke(kind: .up, timeMs: $0 + 40, character: "a")]
        }
        // Shortcuts: ⌘C, ⌘V, ⌘⇧4 and ⌥⌫ for the Shortcuts track.
        for (t, c, m) in [(2000.0, "c", [KeyModifier.command]), (2600, "v", [.command]), (8000, "$", [.command, .shift]), (12_000, "\u{7F}", [.option])] {
            keys += [Keystroke(kind: .down, timeMs: t, character: c, activeModifiers: m), Keystroke(kind: .up, timeMs: t + 90, character: c, activeModifiers: m)]
        }
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 3024, height: 1964), pointPixelScale: 2, durationMs: 42_000, fps: 60, audioSources: [.systemAudio, .microphone]),
            mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(100, 100))] + clicks,
            markersMs: [9000, 20000],
            keystrokes: keys
        )
        project.regenerateAutomaticZooms()
        // × between 30 and 36 s, and 36–38 s cut out.
        project.splitSlice(at: 30_000)
        project.splitSlice(at: 36_000)
        project.slices[1].timeScale = 0.5
        project.updateSlice(project.slices[2].id, sourceStartMs: 38_000)
        project.masks = [
            MaskRange(startMs: 6000, endMs: 9000, bounds: [Rect2(x: 1100, y: 800, width: 700, height: 160)]),
            MaskRange(startMs: 21_000, endMs: 25_000, bounds: [Rect2(x: 400, y: 300, width: 900, height: 500)], type: .highlight),
        ]
        // A webcam (the movie itself is absent) so the camera panels are enabled.
        project.recording.cameraFileName = "camera.mov"
        project.recording.cameraSize = Size2(width: 1920, height: 1080)
        let controller = EditorWindowController(bundleURL: bundle, project: project)
        guard let window = controller.window, let view = window.contentView else { return }
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1440, height: 860), display: true)
        window.orderFrontRegardless()
        let states: [(String, () -> Void)] = [
            ("general", { controller.model.openSidebar(.background) }),
            ("cursor", { controller.model.openSidebar(.cursor) }),
            ("animations", { controller.model.openSidebar(.animation) }),
            ("audio", { controller.model.openSidebar(.audio) }),
            ("camera-layout", { controller.model.openSidebar(.cameraLayout) }),
            ("camera-layout-silence", { controller.model.change { $0.camera.hideDuringSilenceMs = 5000 } }),
            ("camera-layout-split", { controller.model.change { $0.camera.hideDuringSilenceMs = nil }
                 controller.model.change { $0.defaultLayout.type = .splitScreen } }),
            ("camera-layout-cutout", { controller.model.change { $0.defaultLayout.type = .cutoutCamera } }),
            ("camera-style", { controller.model.change { $0.defaultLayout.type = .cameraOverlay }; controller.model.openSidebar(.cameraStyle) }),
            ("captions", { controller.model.openSidebar(.captions) }),
            ("shortcuts", { controller.model.change { $0.captions.enableShortcuts = true; $0.captions.hiddenShortcuts = ["8000": true] }; controller.model.openSidebar(.shortcuts) }),
            ("captions-ready", {
                controller.model.transcript = SessionTranscript(generator: .system(locale: "en_US"), transcript: [TranscriptWord(index: 0, startMs: 1000, endMs: 1400, text: "Hello")])
            }),
            ("transcript-edit", {
                let text = ["So", " um", " today", " we", " look", " at", " the", " new", " editor.", " It", " cuts", " words", " out", " of", " the", " video."]
                controller.model.transcript = SessionTranscript(generator: .system(locale: "en_US"), transcript: text.enumerated().map { i, w in
                    let start = 2000 + Double(i) * 300 + (i >= 9 ? 1500 : 0)
                    return TranscriptWord(index: i, startMs: start, endMs: start + 250, text: w)
                })
                controller.model.openSidebar(.transcript)
            }),
            ("command-menu", { controller.model.transcript = nil
                 controller.model.openSidebar(.background); controller.model.isCommandMenuOpen = true }),
            ("zoom", { if let first = controller.model.project.zooms.first { controller.model.openZoom(first.id) } }),
            ("device-frame", {
                controller.model.change {
                    $0.recording.mode = .externalDevice
                    $0.recording.videoSize = Size2(width: 1206, height: 2622)
                }
                controller.model.openSidebar(.deviceFrame)
            }),
            ("zoom-loupe", {
                if let first = controller.model.project.zooms.first {
                    controller.model.updateZoom(first.id) { $0.presentation = .loupe }
                    controller.model.openZoom(first.id)
                }
            }),
            ("mask", { if let mask = controller.model.project.masks.first { controller.model.openMask(mask.id) } }),
            ("layout", {
                controller.model.seek(to: 11_000)
                controller.model.change {
                    $0.cameraLayouts = [
                        CameraLayoutRange(startMs: 10_000, endMs: 14_000, overlayPosition01: Vec2(0, 0)),
                        CameraLayoutRange(startMs: 17_000, endMs: 20_000, type: .fullscreenCamera),
                    ]
                }
                if let layout = controller.model.project.cameraLayouts.first { controller.model.openLayout(layout.id) }
            }),
            ("layout-tool", { controller.model.sidebarItem = nil; controller.model.armOrAddLayout(.cameraOverlay) }),
            ("slice", { controller.model.isAddLayoutToolArmed = false
                 if let clip = controller.model.project.slices.dropFirst().first { controller.model.openSlice(clip.id) } }),
        ]
        for (name, apply) in states {
            controller.model.isCommandMenuOpen = false
            apply()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("editor-\(name).png"))
            }
        }
        controller.model.isCommandMenuOpen = false
        write(ColorPresetStudioView(model: ColorPresetStudioModel(editor: controller.model), close: {}, onCreated: {}).background(Theme.Colors.background), width: 960, height: 720, to: directory.appendingPathComponent("color-preset-studio.png"))
        controller.model.change { $0.camera.hideDuringSilenceMs = 5000 }
        write(CameraLayoutPanel(editor: controller.model).padding(24).background(Theme.Colors.backgroundAccent), width: 360, height: nil, to: directory.appendingPathComponent("panel-camera-layout.png"))
        controller.model.change { $0.camera.hideDuringSilenceMs = nil }
        let crop = CameraCropModel(editor: controller.model)
        crop.state.setCrop(Rect2(x: 500, y: 150, width: 800, height: 700))
        write(CameraCropView(model: crop, close: {}).background(Theme.Colors.background), width: 960, height: 720, to: directory.appendingPathComponent("camera-crop.png"))
        // Responsiveness: the smallest window and a large one.
        controller.model.openSidebar(.background)
        for (name, size) in [("min", NSSize(width: 1280, height: 740)), ("large", NSSize(width: 2200, height: 1300))] {
            window.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("editor-size-\(name).png"))
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
