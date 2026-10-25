import AVFoundation
import AppKit
import Combine
import RegravaCore
import SwiftUI

// The quick export widget shown instead of the editor right after a recording.

/// A floating window looping the styled project with Save… / Copy / Edit. It does not take focus,
/// keeps the canvas aspect at 230 px tall (at least 270 wide) and opens 40 pt from the left and
/// 120 pt from the bottom of the screen, remembering only its position.
@MainActor
final class QuickExportWidgetController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private var cancellables: Set<AnyCancellable> = []
    private static let positionKey = "quick-export-widget-origin"

    init(bundleURL: URL, project: Project, autoAction: AfterRecordingAction?) {
        model = EditorModel(bundleURL: bundleURL, project: project)
        model.isNewRecording = true
        model.forcesLoop = true
        let canvas = project.canvasSize
        var size = CGSize(width: (230 * canvas.aspectRatio).rounded(), height: 230)
        if size.width < 270 {
            let scale = 270 / size.width
            size = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentAspectRatio = size
        window.contentMinSize = size
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect
        super.init(window: window)
        window.delegate = self
        let host = FirstMouseHostingView(rootView: QuickExportWidgetView(controller: self, editor: model, autoAction: autoAction).environment(\.colorScheme, .dark))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            window.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 120))
        }
        // Closes itself once an export completed (not when it was stopped or failed).
        model.exports.$lastOutcome
            .dropFirst()
            .sink { [weak self] outcome in if outcome == .completed { self?.closeWithoutAsking() } }
            .store(in: &cancellables)
        Task {
            await model.prepare()
            model.player.isMuted = Preferences.shared.muteQuickExportWidgetPreview
            if !model.exports.isExporting { model.togglePlay() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shown without taking focus (`autofocus: false`).
    func present() {
        window?.orderFrontRegardless()
        positionTrafficLights()
    }

    /// "Edit" or a double-click: the full editor for the same project.
    func openEditor() {
        closeWithoutAsking()
        AppController.shared.openProject(bundle: model.bundleURL, project: model.project, isNewRecording: model.isNewRecording && model.project.lastSavedAt == nil, autoplay: true)
    }

    func closeWithoutAsking() {
        guard let window else { return }
        window.delegate = nil
        finish()
        window.close()
    }

    /// The editor's close confirmation unless "always save" is on.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if Preferences.shared.alwaysSaveProjectWhenUsingQuickExportWidget {
            if model.isDirty { model.saveNow() }
            return true
        }
        let isNew = model.isNewRecording && model.project.lastSavedAt == nil
        guard isNew || model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = isNew ? "Do you want to save your project before closing or delete it?" : "Your project has unsaved changes. Are you sure you want to close?"
        alert.addButton(withTitle: "Save and close")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: isNew ? "Delete and close" : "Close without saving")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.saveNow()
            return true
        case .alertThirdButtonReturn:
            if isNew { model.trashProject() } else { model.discardChanges() }
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) { finish() }
    func windowDidResize(_ notification: Notification) { positionTrafficLights() }

    func windowDidMove(_ notification: Notification) {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.positionKey)
    }

    private var finished = false

    private func finish() {
        guard !finished else { return }
        finished = true
        model.tearDown()
        AppController.shared.widgetClosed(self)
    }

    /// Traffic lights at (23, 22) of a 60 pt strip.
    private func positionTrafficLights() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let titlebarView = close.superview, let container = titlebarView.superview else { return }
        let height: CGFloat = 60
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        titlebarView.frame = container.bounds
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 23 + CGFloat(index) * 20, y: height - 22 - button.frame.height))
        }
    }
}

/// Buttons answer the first click while the widget is not key (`acceptFirstMouse`).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct QuickExportWidgetView: View {
    let controller: QuickExportWidgetController
    @ObservedObject var editor: EditorModel
    @ObservedObject var exports: ExportController
    @ObservedObject private var preferences = Preferences.shared
    @EnvironmentObject private var clock: PlaybackClock
    var autoAction: AfterRecordingAction?
    @State private var hovered = false
    @State private var isAutoExporting = false

    init(controller: QuickExportWidgetController, editor: EditorModel, autoAction: AfterRecordingAction?) {
        self.controller = controller
        self.editor = editor
        self.exports = editor.exports
        self.autoAction = autoAction
    }

    var body: some View {
        ZStack {
            PlayerSurface(player: editor.player)
                .opacity(exports.isExporting ? 0 : 1)
                .onTapGesture(count: 2) { controller.openEditor() }
            controls
                .opacity(hovered ? 1 : 0)
                .animation(.linear(duration: 0.2), value: hovered)
            WidgetProgressBar(editor: editor)
            if isAutoExporting && exports.job == nil {
                ZStack {
                    Theme.Colors.background.opacity(0.9)
                    ProgressView().controlSize(.large)
                }
                .transition(.opacity)
            }
            ExportStatusOverlay(exports: exports)
                .padding(.top, 45)
        }
        .onHover { hovered = $0 }
        .environmentObject(editor.clock)
        .task { await autoExport() }
    }

    /// The after-recording action runs here (on mount).
    private func autoExport() async {
        guard let autoAction else { return }
        let target: ExportTarget
        switch autoAction {
        case .exportAndCopyToClipboard: target = .clipboard
        case .exportAndSaveToFile: target = .file
        default: return
        }
        isAutoExporting = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        export(target)
        isAutoExporting = false
    }

    private func export(_ target: ExportTarget) {
        if target == .file { NSApp.activate(ignoringOtherApps: true) }
        editor.pause()
        exports.start(project: editor.project, videoURL: editor.videoURL, projectName: editor.projectName, settings: preferences.widgetExportSettings.current, target: target)
    }

    private var hasAudio: Bool {
        let recording = editor.project.recording
        return recording.hasMicrophone || recording.hasSystemAudio || recording.hasExternalDeviceAudio
    }

    /// Every recorded sound muted in the project itself.
    private var projectMuted: Bool {
        let recording = editor.project.recording, audio = editor.project.audio
        return (!recording.hasMicrophone || audio.muteMicrophone) && (!recording.hasSystemAudio || audio.muteSystemAudio)
            && (!recording.hasExternalDeviceAudio || audio.muteExternalDeviceAudio)
    }

    private var isMuted: Bool { preferences.muteQuickExportWidgetPreview || projectMuted }

    private var controls: some View {
        VStack(spacing: Theme.gap(1)) {
            VStack(spacing: Theme.gap(1)) {
                RSButton(title: "Save...", icon: "square.and.arrow.down.fill", kind: .translucent, size: .small, isWide: true) { export(.file) }
                    .tooltip("Save to file...")
                RSButton(title: "Copy", icon: "document.on.clipboard", kind: .translucent, size: .small, isWide: true) { export(.clipboard) }
                    .tooltip("Copy to clipboard")
                RSButton(title: "Edit", icon: "scribble.variable", kind: .translucent, size: .small, isWide: true) { controller.openEditor() }
                    .tooltip("Continue editing in full editor")
            }
            .padding(.top, 32)
            .frame(maxHeight: .infinity)
            HStack(spacing: Theme.gap(1)) {
                Spacer(minLength: 0)
                Text("Will export \(preferences.widgetExportSettings.current.summary())")
                    .lineLimit(1)
                HStack(spacing: 0) {
                    if hasAudio {
                        RSIconButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", kind: .translucent, size: .small,
                                     tooltip: isMuted ? "Unmute widget preview" : "Mute widget preview") { toggleMute() }
                    }
                    RSIconButton(icon: "gear", kind: .translucent, size: .small, tooltip: "Edit quick export settings") {
                        SettingsWindowController.shared.show(.widget)
                    }
                }
            }
            .font(Theme.Typo.label)
            .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            .frame(height: 20)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }

    /// The preview's own mute, or, when the project's sound is all muted, the project's.
    private func toggleMute() {
        if projectMuted {
            let unmute = isMuted
            editor.change {
                $0.audio.muteMicrophone = !unmute
                $0.audio.muteSystemAudio = !unmute
                $0.audio.muteExternalDeviceAudio = !unmute
            }
            if unmute { preferences.muteQuickExportWidgetPreview = false }
        } else {
            preferences.muteQuickExportWidgetPreview.toggle()
        }
        editor.player.isMuted = preferences.muteQuickExportWidgetPreview
    }
}

/// 3.5 px playback progress along the bottom, over everything.
private struct WidgetProgressBar: View {
    @ObservedObject var editor: EditorModel
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        VStack {
            Spacer()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.Colors.backgroundAccent)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(Theme.secondaryOpacity))
                        .frame(width: geometry.size.width * min(max(clock.currentTimeMs / max(editor.durationMs, 1), 0), 1))
                }
            }
            .frame(height: 3.5)
        }
        .allowsHitTesting(false)
    }
}
