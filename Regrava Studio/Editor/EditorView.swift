@preconcurrency import AVKit
import AppKit
import RegravaCore
import SwiftUI

/// Editor window content.
struct EditorView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var exports: ExportController

    init(editor: EditorModel) {
        self.editor = editor
        exports = editor.exports
    }

    var body: some View {
        VStack(spacing: 0) {
            Topbar(editor: editor, exports: exports)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: Theme.gap(2)) {
                    VStack(spacing: Theme.gap(1)) {
                        HStack(alignment: .top, spacing: Theme.gap(2)) {
                            if editor.layoutType.showsTimeline || editor.layoutType.showsSidebar {
                                AddToolsRail(editor: editor)
                            }
                            PreviewSpace(editor: editor)
                            if editor.layoutType.showsSidebar {
                                SidebarRail(editor: editor)
                            }
                        }
                        PlaybackBar(editor: editor)
                    }
                    if editor.layoutType.showsSidebar {
                        SidebarPanel(editor: editor)
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 14)
                if editor.layoutType.showsTimeline {
                    EditorTimeline(editor: editor)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .foregroundStyle(Theme.Colors.text)
        .overlay {
            if exports.isPickerOpen {
                ExportPickerOverlay(exports: exports, project: editor.project, projectName: editor.projectName, videoURL: editor.videoURL)
            }
        }
        .overlay {
            if exports.isExporting { ExportStatusOverlay(exports: exports) }
        }
        .overlay(alignment: .top) {
            if let message = editor.toast {
                Text(message)
                    .font(Theme.Typo.copy)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Capsule().fill(Theme.Colors.background.opacity(0.92)))
                    .overlay(Capsule().strokeBorder(Theme.Colors.systemBorder))
                    .padding(.top, 72)
                    .transition(.opacity)
                    .task(id: message) {
                        // Info toasts last 2 s.
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if editor.toast == message { editor.toast = nil }
                    }
            }
        }
    }
}

// MARK: - Topbar

private struct Topbar: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var exports: ExportController

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Theme.gap(1)) {
                RSIconButton(icon: "folder", size: .toolbar, tooltip: "Show previous projects") { AppController.shared.showPreviousProjects() }
                RSIconButton(icon: "trash", size: .toolbar, tooltip: "Remove project") {
                    if editor.deleteProject() { AppController.shared.closeEditor(for: editor) }
                }
            }
            .padding(.leading, 90)
            .frame(maxWidth: .infinity, alignment: .leading)

            ProjectTitle(editor: editor)
                .frame(maxWidth: .infinity)

            HStack(spacing: Theme.gap(1)) {
                HStack(spacing: 2) {
                    RSIconButton(icon: "arrow.uturn.backward", size: .toolbar, tooltip: "Undo  ⌘Z") { editor.undo() }
                        .disabled(!editor.canUndo)
                        .opacity(editor.canUndo ? 1 : Theme.disabledOpacity)
                    RSIconButton(icon: "arrow.uturn.forward", size: .toolbar, tooltip: "Redo  ⇧⌘Z") { editor.redo() }
                        .disabled(!editor.canRedo)
                        .opacity(editor.canRedo ? 1 : Theme.disabledOpacity)
                }
                Rectangle().fill(Theme.Colors.systemBorder.opacity(0.6)).frame(width: 1, height: 24)
                RSButton(title: "Export", icon: "square.and.arrow.up.fill", kind: .primary) { editor.openExportPicker() }
                    .disabled(exports.isExporting || exports.isPickerOpen)
                    .help(exports.isExporting ? "Only one export can be active at a time" : "")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.trailing, 14)
        .frame(height: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.backgroundAccent).frame(height: 1) }
    }
}

/// Editable file name + tertiary ".regrava" suffix.
private struct ProjectTitle: View {
    @ObservedObject var editor: EditorModel
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.copy)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused && isEditing { commit() } }
                    .fixedSize()
            } else {
                Text(editor.projectName)
                    .font(Theme.Typo.copy)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture {
                        draft = editor.projectName
                        isEditing = true
                        focused = true
                    }
            }
            Text(".\(ProjectStore.fileExtension)").font(Theme.Typo.copy).foregroundStyle(Theme.Colors.tertiary)
        }
        .frame(maxWidth: 300)
    }

    private func commit() {
        isEditing = false
        editor.rename(to: draft)
        AppController.shared.editorRenamed(editor)
    }
}

// MARK: - Add-tools rail

/// Floating pill: toolbarGlass, radius 16, padding 6; 38×38 icon buttons, tooltips on the right.
private struct AddToolsRail: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(spacing: Theme.gap(2)) {
            VStack(spacing: Theme.gap(0)) {
                RSIconButton(icon: "arrow.up.left.and.down.right.magnifyingglass", kind: editor.isAddZoomToolArmed ? .subtleBg : .transparent, tooltip: "Classic zoom") {
                    editor.isAddZoomToolArmed.toggle()
                    if editor.isAddZoomToolArmed {
                        editor.pause()
                        editor.sidebarItem = nil
                    }
                }
                // The Glass Loupe effect is not rendered by this app yet.
                RSIconButton(icon: "sparkle.magnifyingglass", tooltip: "Loupe zoom") {}
                    .disabled(true)
                    .opacity(Theme.disabledOpacity)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.Colors.systemBorder.opacity(0.5)))
    }
}

// MARK: - Preview

private struct PreviewSpace: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preferences = Preferences.shared

    var body: some View {
        GeometryReader { geometry in
            let canvas = editor.project.canvasSize
            let available = CGSize(width: geometry.size.width, height: max(geometry.size.height - 40, 50))
            let maxHeight = min(available.height, CGFloat(preferences.playbackPreviewMaxHeight) / (NSScreen.main?.backingScaleFactor ?? 2))
            let scale = min(available.width / canvas.width, maxHeight / canvas.height)
            let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            VStack(spacing: Theme.gap(1)) {
                LayoutControls(editor: editor, preferences: preferences, availableHeight: available.height)
                    .frame(width: max(size.width, 420))
                ZStack {
                    PlayerSurface(player: editor.player)
                    if editor.isAddZoomToolArmed {
                        Color.white.opacity(0.001)
                            .onContinuousHover { phase in if case .active = phase { NSCursor.crosshair.set() } }
                            .onTapGesture { location in
                                // "Click the canvas to place a zoom".
                                let target = Vec2(clamp(location.x / size.width, 0, 1), clamp(location.y / size.height, 0, 1))
                                editor.addZoom(startMs: editor.currentSourceTimeMs, manualTarget: target)
                                editor.isAddZoomToolArmed = false
                            }
                        Text("Click the canvas to place a zoom")
                            .font(Theme.Typo.label.weight(.medium))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.background.opacity(0.8)))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contextMenu {
                    Button { editor.copyCurrentFrame() } label: { Label("Copy current frame as image", systemImage: "document.on.document") }
                        .keyboardShortcut("c", modifiers: .command)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// AVPlayerView without controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Aspect-ratio picker (left); preview quality and size (right).
private struct LayoutControls: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var preferences: Preferences
    var availableHeight: CGFloat

    private static let sizeSteps = [480, 720, 1080, 1440, 2160]
    private static let qualities: [(String, Double)] = [("Full", 1), ("Half", 0.5), ("Quarter", 0.25)]

    var body: some View {
        HStack(spacing: Theme.gap(2)) {
            Menu {
                ForEach(OutputAspect.all, id: \.label) { option in
                    Button {
                        editor.change { $0.style.aspectRatio = option.ratio }
                    } label: {
                        let title = option.ratioLabel.map { "\(option.label)  \($0)" } ?? option.label
                        if editor.project.style.aspectRatio == option.ratio { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                    .help(option.tip ?? "")
                }
            } label: {
                Label(currentAspect.label, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Output aspect ratio")

            Spacer()

            HStack(spacing: Theme.gap(0)) {
                Menu {
                    ForEach(Self.qualities, id: \.1) { quality in
                        Button {
                            preferences.playbackPreviewResolution = quality.1
                        } label: {
                            let title = "\(quality.0)  \(Int((Double(preferences.playbackPreviewMaxHeight) * quality.1).rounded()))p"
                            if preferences.playbackPreviewResolution == quality.1 { Label(title, systemImage: "checkmark") } else { Text(title) }
                        }
                    }
                } label: {
                    Label("Preview quality \(Self.qualities.first { $0.1 == preferences.playbackPreviewResolution }?.0 ?? "Full")", systemImage: "circle.hexagongrid")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                RSIconButton(icon: "minus.magnifyingglass", size: .small, tooltip: "Decrease preview size") { step(-1) }
                    .disabled(smaller == nil)
                    .opacity(smaller == nil ? Theme.disabledOpacity : 1)
                RSIconButton(icon: "plus.magnifyingglass", size: .small, tooltip: "Increase preview size") { step(1) }
                    .disabled(larger == nil)
                    .opacity(larger == nil ? Theme.disabledOpacity : 1)
            }
        }
        .font(Theme.Typo.label)
        .frame(height: 32)
    }

    private var currentAspect: OutputAspect {
        OutputAspect.all.first { $0.ratio == editor.project.style.aspectRatio } ?? OutputAspect.all[0]
    }

    private var smaller: Int? { Self.sizeSteps.last { $0 < preferences.playbackPreviewMaxHeight } }
    private var larger: Int? {
        Self.sizeSteps.first { $0 > preferences.playbackPreviewMaxHeight && CGFloat($0) / 2 <= availableHeight * 1.5 }
    }

    private func step(_ direction: Int) {
        if direction < 0, let smaller { preferences.playbackPreviewMaxHeight = smaller }
        if direction > 0, let larger { preferences.playbackPreviewMaxHeight = larger }
    }
}

// MARK: - Playback bar

private struct PlaybackBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let showsTimes = geometry.size.width >= 700
            HStack(spacing: 0) {
                HStack(spacing: Theme.gap(1)) {
                    if editor.layoutType.showsTimeline {
                        RSIconButton(icon: "scissors", kind: editor.isSplitToolActive ? .subtleBg : .transparent, size: .toolbar, tooltip: "Split clip  ⌥") {
                            editor.isSplitToolActive.toggle()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Theme.gap(2)) {
                    if showsTimes { TimeLabel(ms: editor.currentTimeMs, duration: editor.durationMs, omitFrames: editor.isPlaying) }
                    RSIconButton(icon: "backward.end", size: .toolbar, tooltip: "Go to first frame  ⌘←") { editor.seek(to: 0) }
                    Button(action: editor.togglePlay) {
                        Image(systemName: editor.isPlaying ? "pause.circle" : "play.circle")
                            .font(.system(size: 22))
                            .frame(width: 56, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(editor.isPlaying ? "Pause" : "Play")
                    RSIconButton(icon: "forward.end", size: .toolbar, tooltip: "Go to last frame  ⌘→") { editor.seek(to: editor.durationMs) }
                    if showsTimes { TimeLabel(ms: editor.durationMs, duration: editor.durationMs, omitFrames: false) }
                }

                HStack(spacing: Theme.gap(1)) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Theme.Colors.backgroundAccent).frame(width: 1, height: 24)
                    SpeedButton(editor: editor)
                    if editor.layoutType.showsTimeline {
                        RSSlider(
                            value: Binding(get: { editor.visibleDurationMs }, set: { editor.setVisibleDuration($0, anchorMs: editor.currentTimeMs) }),
                            range: editor.minVisibleDurationMs...editor.maxVisibleDurationMs,
                            step: 1,
                            inverted: true
                        )
                        .frame(minWidth: 72, maxWidth: 140)
                        .help(Self.zoomTooltip(editor.visibleDurationMs))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 38)
        .padding(.bottom, editor.layoutType.showsTimeline ? 0 : 12)
    }

    static func zoomTooltip(_ ms: Double) -> String {
        let s = ms / 1000
        return s < 60 ? "Timeline zoom — \(Int(s.rounded())) seconds visible" : "Timeline zoom — \(Int((s / 60).rounded())) minutes visible"
    }
}

/// M:SS.FF / MM:SS.FF / HH:MM:SS.FF; click copies.
private struct TimeLabel: View {
    var ms: Double
    var duration: Double
    var omitFrames: Bool
    @State private var hovered = false

    var body: some View {
        Text(Self.format(ms, duration: duration, omitFrames: omitFrames))
            .font(Theme.Typo.copy.monospacedDigit())
            .foregroundStyle(Theme.Colors.tertiary)
            .opacity(hovered ? 0.8 : 1)
            .frame(height: 38)
            .onHover { hovered = $0 }
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.format(ms, duration: duration, omitFrames: false), forType: .string)
            }
            .help("Copy to clipboard")
    }

    static func format(_ ms: Double, duration: Double, omitFrames: Bool) -> String {
        let total = max(ms, 0) / 1000
        let frames = Int((total - floor(total)) * 60)
        let s = Int(total)
        let base: String
        if duration > 3_600_000 {
            base = String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        } else if duration >= 600_000 {
            base = String(format: "%02d:%02d", s / 60, s % 60)
        } else {
            base = String(format: "%d:%02d", s / 60, s % 60)
        }
        return omitFrames ? base : base + String(format: ".%02d", frames)
    }
}

/// "1×": click cycles 1→2→4→8; right-click menu with Slower/Normal/Faster groups.
private struct SpeedButton: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        Button(action: editor.cyclePlaybackRate) {
            Text(String(format: "%g×", editor.playbackRate))
                .font(Theme.Typo.copy.weight(.medium).monospacedDigit())
                .frame(minWidth: 38)
                .frame(height: 38)
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .contextMenu {
            Section("Slower") {
                speedItem(0.25)
                speedItem(0.5)
            }
            Section("Normal") { speedItem(1) }
            Section("Faster") {
                speedItem(2)
                speedItem(4)
                speedItem(8)
            }
        }
    }

    private func speedItem(_ rate: Double) -> some View {
        Button {
            editor.setPlaybackRate(rate)
        } label: {
            if editor.playbackRate == rate { Label(String(format: "%g×", rate), systemImage: "checkmark") } else { Text(String(format: "%g×", rate)) }
        }
    }
}
