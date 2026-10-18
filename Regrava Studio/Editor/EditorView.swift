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
        .overlay {
            if editor.isCommandMenuOpen { CommandMenuOverlay(editor: editor) }
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
                        // Info toasts last 2 s; preview markers use 1 s.
                        try? await Task.sleep(nanoseconds: UInt64(editor.toastDurationMs * 1_000_000))
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
                RSIconButton(icon: "command.circle", size: .toolbar, tooltip: "Show command menu...  ⌘K") { editor.isCommandMenuOpen = true }
                Rectangle().fill(Theme.Colors.systemBorder.opacity(0.6)).frame(width: 1, height: 24)
                HStack(spacing: 2) {
                    RSIconButton(icon: "arrow.uturn.backward", size: .toolbar, tooltip: "Undo  ⌘Z") { editor.undo() }
                        .disabled(!editor.canUndo)
                        .opacity(editor.canUndo ? 1 : Theme.disabledOpacity)
                    RSIconButton(icon: "arrow.uturn.forward", size: .toolbar, tooltip: "Redo  ⇧⌘Z") { editor.redo() }
                        .disabled(!editor.canRedo)
                        .opacity(editor.canRedo ? 1 : Theme.disabledOpacity)
                }
                Rectangle().fill(Theme.Colors.systemBorder.opacity(0.6)).frame(width: 1, height: 24)
                PresetsButton(editor: editor)
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
            // Mask group.
            VStack(spacing: Theme.gap(0)) {
                ForEach([MaskType.sensitiveData, .highlight], id: \.self) { type in
                    RSIconButton(
                        icon: type == .sensitiveData ? "circle.filled.pattern.diagonalline.rectangle" : "circle.rectangle.filled.pattern.diagonalline",
                        kind: editor.isAddMaskToolArmed && editor.addMaskType == type ? .subtleBg : .transparent,
                        tooltip: type == .sensitiveData ? "Sensitive data mask" : "Highlight mask"
                    ) { editor.armMaskTool(type) }
                }
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
                .overlay { PreviewMarkers(editor: editor, scale: scale) }
                .overlay { MaskOverlays(editor: editor, scale: scale) }
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
                            inverted: true,
                            isSecondary: true
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
            .lineLimit(1)
            .fixedSize()
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

// MARK: - Mask overlays

private struct MaskOverlays: View {
    @ObservedObject var editor: EditorModel
    var scale: CGFloat
    @State private var drawing: CGRect?

    var body: some View {
        if !editor.isPlaying {
            let area = editor.recordingAreaRect
            let areaRect = CGRect(x: area.x * scale, y: area.y * scale, width: area.width * scale, height: area.height * scale)
            ZStack(alignment: .topLeading) {
                if editor.isAddMaskToolArmed {
                    drawTool(areaRect)
                } else if let id = editor.openMaskID, let mask = editor.project.masks.first(where: { $0.id == id }), let bound = mask.firstBound {
                    // Clicking outside the rectangle finishes editing.
                    Color.white.opacity(0.001).onTapGesture { editor.sidebarItem = nil }
                    MaskRectEditor(
                        rect: rect(bound, in: areaRect),
                        area: areaRect,
                        onChange: { newRect in
                            editor.updateMask(id, coalesce: "mask-bounds-\(id)") { mask in
                                mask.bounds = [recording(newRect, mask.bounds.first ?? bound, area: areaRect)]
                            }
                        }
                    )
                } else if let mask = visibleMask, let bound = mask.firstBound {
                    // A shown mask can be clicked to edit it.
                    MarkerArea(rect: rect(bound, in: areaRect), cornerRadius: 4) {
                            let t = editor.currentSourceTimeMs
                            if t < mask.startMs { editor.seek(to: editor.project.resolver.sourceToPlayback(mask.startMs)) }
                            if t > mask.endMs { editor.seek(to: editor.project.resolver.sourceToPlayback(mask.endMs)) }
                            editor.openMask(mask.id)
                    }
                }
            }
        }
    }

    private var visibleMask: MaskRange? {
        let t = editor.currentSourceTimeMs
        let masks = editor.project.sortedMasks
        if let here = masks.first(where: { $0.contains(t) }) { return here.canShow ? here : nil }
        return masks.first { $0.isWithinShowWindow(t) }
    }

    private func rect(_ bound: Rect2, in area: CGRect) -> CGRect {
        let size = editor.project.recording.videoSize
        return CGRect(
            x: area.minX + bound.x / size.width * area.width,
            y: area.minY + bound.y / size.height * area.height,
            width: bound.width / size.width * area.width,
            height: bound.height / size.height * area.height
        )
    }

    private func recording(_ rect: CGRect, _ fallback: Rect2, area: CGRect) -> Rect2 {
        guard area.width > 0, area.height > 0 else { return fallback }
        let size = editor.project.recording.videoSize
        return Rect2(
            x: (rect.minX - area.minX) / area.width * size.width,
            y: (rect.minY - area.minY) / area.height * size.height,
            width: rect.width / area.width * size.width,
            height: rect.height / area.height * size.height
        )
    }

    /// "Drag on the canvas to draw the mask"; a click places a 350×80 mask.
    private func drawTool(_ area: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
                .onContinuousHover { phase in if case .active = phase { NSCursor.crosshair.set() } }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("mask-surface"))
                        .onChanged { value in
                            let a = clampPoint(value.startLocation, area), b = clampPoint(value.location, area)
                            drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        }
                        .onEnded { value in
                            let drawn = drawing
                            drawing = nil
                            let size = editor.project.recording.videoSize
                            if let drawn, drawn.width >= 6, drawn.height >= 6 {
                                editor.addMask(type: editor.addMaskType, bounds: recording(drawn, Rect2(x: 0, y: 0, width: size.width, height: size.height), area: area))
                            } else if abs(value.translation.width) < 3 && abs(value.translation.height) < 3 {
                                let p = clampPoint(value.location, area)
                                let point01 = Vec2((p.x - area.minX) / max(area.width, 1), (p.y - area.minY) / max(area.height, 1))
                                editor.addMask(type: editor.addMaskType, bounds: editor.project.clickedMaskBounds(at: point01))
                            }
                        }
                )
            if let drawing {
                Rectangle()
                    .fill(Theme.Colors.primary.opacity(0.1))
                    .overlay(Rectangle().strokeBorder(Theme.Colors.primary.opacity(0.9), lineWidth: 1.5))
                    .frame(width: drawing.width, height: drawing.height)
                    .offset(x: drawing.minX, y: drawing.minY)
                    .allowsHitTesting(false)
            }
            Text("Drag on the canvas to draw the mask")
                .font(Theme.Typo.label.weight(.medium))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.background.opacity(0.8)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: "mask-surface")
    }

    private func clampPoint(_ p: CGPoint, _ area: CGRect) -> CGPoint {
        CGPoint(x: clamp(p.x, area.minX, area.maxX), y: clamp(p.y, area.minY, area.maxY))
    }
}

/// Rectangle editor over the recording (the crop-area control): move by dragging inside,
/// resize by the corner and edge handles, centre lines at 50%.
private struct MaskRectEditor: View {
    var rect: CGRect
    var area: CGRect
    var onChange: (CGRect) -> Void
    @State private var origin: CGRect?

    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                .overlay {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1)
                        Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1)
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .gesture(drag { start, t in
                    var moved = start.offsetBy(dx: t.width, dy: t.height)
                    moved.origin.x = clamp(moved.minX, area.minX, area.maxX - moved.width)
                    moved.origin.y = clamp(moved.minY, area.minY, area.maxY - moved.height)
                    return moved
                })
            ForEach(Handle.allCases, id: \.self) { handle in
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .offset(x: point(handle).x - 5, y: point(handle).y - 5)
                    .gesture(drag { start, t in resize(start, handle, t) })
            }
        }
    }

    private func point(_ handle: Handle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func resize(_ start: CGRect, _ handle: Handle, _ t: CGSize) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = clamp(minX + t.width, area.minX, maxX - 6)
        case .topRight, .right, .bottomRight: maxX = clamp(maxX + t.width, minX + 6, area.maxX)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = clamp(minY + t.height, area.minY, maxY - 6)
        case .bottomLeft, .bottom, .bottomRight: maxY = clamp(maxY + t.height, minY + 6, area.maxY)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drag(_ transform: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = origin ?? rect
                if origin == nil { origin = rect }
                onChange(transform(start, value.translation))
            }
            .onEnded { _ in origin = nil }
    }
}

/// "Presets" dropdown (`wand.and.rays`, transparent, active while open).
private struct PresetsButton: View {
    @ObservedObject var editor: EditorModel
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: Theme.gap(1)) {
                Image(systemName: "wand.and.rays")
                Text("Presets")
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
        }
        .buttonStyle(RSButtonStyle(kind: isOpen ? .subtleBg : .transparent))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { PresetsPopover(editor: editor) }
    }
}
