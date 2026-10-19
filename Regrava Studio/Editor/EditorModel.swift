@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import RegravaCore
import RegravaRender

/// Sidebar sections, in rail order.
enum SidebarRoot: String, CaseIterable {
    case background, cursor, cameraLayout, cameraStyle, captions, transcript, audio, shortcuts, animation, deviceFrame
}

/// A timeline item opened in the sidebar.
enum SidebarItem: Equatable {
    case zoom(UUID)
    case slice(UUID)
    case mask(UUID)
    case layout(UUID)
}

/// `view.layoutType`.
enum EditorLayoutType {
    case edit, hideSidebar, hideTimeline, preview

    var showsTimeline: Bool { self == .edit || self == .hideSidebar }
    var showsSidebar: Bool { self == .edit || self == .hideTimeline }
}

/// State and actions of one project window.
@MainActor
final class EditorModel: ObservableObject {
    private(set) var bundleURL: URL
    let player = AVPlayer()
    let exports = ExportController()
    private let preferences = Preferences.shared

    @Published private(set) var project: Project
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // Playback
    @Published private(set) var currentTimeMs: Double = 0
    @Published private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { updateRenderQuality() } }
    }
    /// `playback.defaultRate`: 0.25…8.
    @Published var playbackRate: Double = 1

    // View state
    @Published var layoutType: EditorLayoutType = .edit
    @Published var sidebarRoot: SidebarRoot = .background
    @Published var sidebarItem: SidebarItem?
    @Published var selectedZoomIDs: Set<UUID> = []
    /// Zoom add tool armed from the add-tools rail.
    @Published var isAddZoomToolArmed = false
    /// Command menu (⌘K).
    @Published var isCommandMenuOpen = false
    /// Mask add tool (`activeAddTool = "mask"`, `addMaskType`).
    @Published var isAddMaskToolArmed = false
    @Published var addMaskType: MaskType = .sensitiveData
    /// Layout add tool (`activeAddTool = "layout"`); only camera overlay arms it.
    @Published var isAddLayoutToolArmed = false
    /// Last layout type chosen from the add tools (`addLayoutType`), used by ⌃L.
    @Published var addLayoutType: CameraLayoutType = .cameraOverlay
    @Published var isSplitToolActive = false
    /// Visible timeline duration (zoom level of the timeline).
    @Published var visibleDurationMs: Double = 30_000
    /// Left edge of the visible timeline range.
    @Published var scrollOffsetMs: Double = 0
    /// "zooms" track is focused by default; nil = none.
    @Published var focusedTrack: String? = "zooms"
    @Published var errorMessage: String?
    /// Short message shown over the editor (e.g. "Copied to clipboard").
    @Published var toast: String?
    /// How long the toast stays (2 s for info toasts, 1 s for the preview markers).
    var toastDurationMs: Double = 2000

    func showToast(_ message: String, durationMs: Double = 2000) {
        toastDurationMs = durationMs
        toast = message
    }

    private let cursors: CursorLibrary
    private let renderState: RenderState
    private var baseConfiguration: AVVideoComposition.Configuration?
    private var compositionCanvas: Size2?
    private var compositionOutput: Size2?
    private var timeObserver: Any?
    private var refreshTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastCoalesceKey: String?
    private var lastChangeAt = Date.distantPast
    private var isScrubbing = false {
        didSet { if oldValue != isScrubbing { updateRenderQuality() } }
    }
    private var cancellables: Set<AnyCancellable> = []

    init(bundleURL: URL, project: Project) {
        self.bundleURL = bundleURL
        self.project = project
        cursors = CursorLibrary.make(project: project, bundle: bundleURL)
        renderState = RenderState(project: project, cursors: cursors, assetsDirectory: bundleURL)
        let saved = UserDefaults.standard.double(forKey: "project-view-timeline-zoom.\(bundleURL.path)")
        visibleDurationMs = clampVisibleDuration(saved > 0 ? saved : 30_000)
        Publishers.Merge(preferences.$playbackPreviewResolution.map { _ in () }, preferences.$playbackPreviewMaxHeight.map { _ in () })
            .dropFirst()
            .sink { [weak self] in DispatchQueue.main.async { Task { await self?.rebuildComposition() } } }
            .store(in: &cancellables)
    }

    /// Playback duration (clips sped up, slowed down or cut).
    var durationMs: Double { project.playbackDurationMs }
    var projectName: String { bundleURL.deletingPathExtension().lastPathComponent }
    var videoURL: URL { ProjectStore.videoURL(bundle: bundleURL, project: project) }

    func prepare() async {
        await rebuildComposition()
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = self.player.rate != 0
                if !self.isScrubbing || self.isPlaying {
                    self.currentTimeMs = time.seconds * 1000
                    if self.isPlaying { self.followPlayhead() }
                }
            }
        }
    }

    // MARK: Changes & history

    /// Applies a change with undo support. Changes sharing `coalesce` within one second
    /// (slider drags, timeline drags) form a single undo step.
    func change(coalesce key: String? = nil, _ body: (inout Project) -> Void) {
        var updated = project
        body(&updated)
        guard updated != project else { return }
        let now = Date()
        if !(key != nil && key == lastCoalesceKey && now.timeIntervalSince(lastChangeAt) < 1) {
            undoStack.append(project)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastCoalesceKey = key
        lastChangeAt = now
        apply(updated)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        lastCoalesceKey = nil
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        lastCoalesceKey = nil
        apply(next)
    }

    private func apply(_ updated: Project) {
        let canvasChanged = updated.canvasSize != project.canvasSize
        let slicesChanged = updated.slices != project.slices
        let backgroundChanged = updated.audio.backgroundAudioFileName != project.audio.backgroundAudioFileName
            || updated.audio.muteBackgroundAudio != project.audio.muteBackgroundAudio
            || (updated.audio.backgroundAudioVolume > 0) != (project.audio.backgroundAudioVolume > 0)
        let audioChanged = updated.audio != project.audio
        let cameraDelayChanged = updated.camera.delayAdjustmentMs != project.camera.delayAdjustmentMs
        project = updated
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if case .zoom(let id) = sidebarItem, !project.zooms.contains(where: { $0.id == id }) { sidebarItem = nil }
        if case .slice(let id) = sidebarItem, !project.slices.contains(where: { $0.id == id }) { sidebarItem = nil }
        if case .mask(let id) = sidebarItem, !project.masks.contains(where: { $0.id == id }) { sidebarItem = nil }
        if case .layout(let id) = sidebarItem, !project.cameraLayouts.contains(where: { $0.id == id }) { sidebarItem = nil }
        selectedZoomIDs = selectedZoomIDs.filter { id in project.zooms.contains { $0.id == id } }
        isDirty = true
        scheduleAutosave()
        rememberLastProjectConfig()
        if canvasChanged || slicesChanged || backgroundChanged || cameraDelayChanged {
            Task { await rebuildComposition(replacingItem: slicesChanged || backgroundChanged || cameraDelayChanged) }
        } else {
            if audioChanged { Task { await refreshAudioMix() } }
            scheduleRefresh()
        }
    }

    // MARK: Rendering

    /// Refresh rate of the fastest display (60, or 120 with ProMotion).
    static var displayFrameRate: Int {
        max(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60, 30)
    }

    private var previewOutputSize: Size2 {
        let canvas = project.canvasSize
        let height = min(canvas.height, Double(preferences.playbackPreviewMaxHeight)) * preferences.playbackPreviewResolution
        let width = (height * canvas.aspectRatio / 2).rounded() * 2
        return Size2(width: width, height: (height / 2).rounded() * 2)
    }

    /// New composition (canvas or preview size changed); keeps the playhead. With
    /// `replacingItem` the player gets a new item, needed when clips change the timing.
    func rebuildComposition(replacingItem: Bool = false) async {
        let snapshot = RenderState.makeSnapshot(project: project, cursors: cursors, assetsDirectory: bundleURL)
        renderState.replace(with: snapshot)
        do {
            let media = try await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundleURL))
            let asset = media.asset
            let output = previewOutputSize
            // Frames at the display's refresh rate: screen recordings have a variable, lower frame rate,
            // which made zooms and the cursor judder.
            let configuration = try await CompositionFactory.configuration(asset: asset, state: renderState, canvas: project.canvasSize, outputSize: output, fps: Self.displayFrameRate)
            let composition = AVVideoComposition(configuration: configuration)
            baseConfiguration = configuration
            prewarmRenderer()
            compositionCanvas = project.canvasSize
            compositionOutput = output
            if let item = player.currentItem, !replacingItem {
                item.videoComposition = composition
                item.audioMix = media.audioMix
            } else {
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .spectral
                item.videoComposition = composition
                item.audioMix = media.audioMix
                player.replaceCurrentItem(with: item)
            }
            if !isPlaying { seek(to: min(currentTimeMs, durationMs)) }
        } catch {
            errorMessage = "Could not load the recording: \(error.localizedDescription)"
        }
    }

    /// Volumes and mutes only change the mix of the current item.
    private func refreshAudioMix() async {
        guard let media = try? await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundleURL)) else { return }
        player.currentItem?.audioMix = media.audioMix
    }

    // MARK: Presets

    private var lastConfigTask: Task<Void, Never>?

    /// With "use last project config", the edited settings are kept for new projects after
    /// 3 s without changes.
    private func rememberLastProjectConfig() {
        guard preferences.useLastProjectConfigForNewProjects else { return }
        lastConfigTask?.cancel()
        let config = project.presetConfig
        lastConfigTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(config) else { return }
            UserDefaults.standard.set(data, forKey: "lastProjectConfig")
        }
    }

    /// Settings shown while hovering a preset (`project.presetPreview`); not part of history.
    var presetPreview: PresetConfig? {
        didSet { if presetPreview != oldValue { scheduleRefresh() } }
    }

    /// The project as rendered (with the hovered preset, if any).
    private var renderedProject: Project {
        guard let presetPreview else { return project }
        var preview = project
        preview.apply(presetPreview)
        return preview
    }

    func previewPreset(_ entry: PresetStore.Entry?) {
        if let entry { PresetStore.shared.copyAssets(of: entry, into: bundleURL) }
        presetPreview = entry?.preset.config
    }

    func applyPreset(_ entry: PresetStore.Entry) {
        PresetStore.shared.copyAssets(of: entry, into: bundleURL)
        presetPreview = nil
        change { $0.apply(entry.preset.config) }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let project = self.renderedProject
        let cursors = self.cursors
        let bundle = bundleURL
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                RenderState.makeSnapshot(project: project, cursors: cursors, assetsDirectory: bundle)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.renderState.replace(with: snapshot)
            self.prewarmRenderer()
            // Re-assigning the composition drops cached frames.
            if let base = self.baseConfiguration, let item = self.player.currentItem {
                item.videoComposition = AVVideoComposition(configuration: base)
                if !self.isPlaying { self.seek(to: self.isScrubbing ? self.scrubTimeMs : self.currentTimeMs, moveHead: false) }
            }
        }
    }

    private var prewarmTask: Task<Void, Never>?

    /// Compiles the moving-frame programs in the background so playback does not stall on them.
    private func prewarmRenderer() {
        prewarmTask?.cancel()
        let state = renderState, output = previewOutputSize
        prewarmTask = Task.detached(priority: .utility) {
            CompositionFactory.prewarm(state: state, outputSize: output)
        }
    }

    /// Lighter motion blur while playing, full quality when paused (`wf.qualityByMode`). A frame
    /// left on screen after playback or scrubbing is drawn again at full quality.
    private func updateRenderQuality() {
        let quality: RenderQuality = isPlaying ? .playing : isScrubbing ? .pausedLow : .pausedHigh
        let previous = renderState.quality
        guard quality != previous else { return }
        renderState.quality = quality
        if quality == .pausedHigh, previous == .playing || previous == .pausedLow,
           let base = baseConfiguration, let item = player.currentItem {
            item.videoComposition = AVVideoComposition(configuration: base)
            seek(to: currentTimeMs, moveHead: false)
        }
    }

    // MARK: Playback

    private var scrubTimeMs: Double = 0

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            isScrubbing = false
            if currentTimeMs >= durationMs - 30 { seek(to: 0) }
            player.rate = Float(playbackRate)
        }
        isPlaying = player.rate != 0
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Moves the playhead (click on the timeline, buttons, shortcuts). Times round to 60 fps.
    func seek(to timeMs: Double, moveHead: Bool = true) {
        let frame = 1000.0 / 60
        let clamped = clamp((timeMs / frame).rounded() * frame, 0, durationMs)
        if moveHead { currentTimeMs = clamped }
        player.seek(to: CMTime(seconds: clamped / 1000, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Hover scrubbing while paused (the head stays where it is).
    func scrub(to timeMs: Double) {
        guard !isPlaying else { return }
        isScrubbing = true
        scrubTimeMs = clamp(timeMs, 0, durationMs)
        seek(to: scrubTimeMs, moveHead: false)
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if !isPlaying { seek(to: currentTimeMs) }
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTimeMs + Double(frames) * 1000 / 60)
    }

    func step(milliseconds: Double) {
        seek(to: currentTimeMs + milliseconds)
    }

    /// Click on the speed button: 1× → 2× → 4× → 8× → 1×.
    func cyclePlaybackRate() {
        let steps: [Double] = [1, 2, 4, 8]
        let index = steps.firstIndex(of: playbackRate) ?? -1
        setPlaybackRate(steps[(index + 1) % steps.count])
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying { player.rate = Float(rate) }
    }

    // MARK: Timeline view

    var minVisibleDurationMs: Double { max(min(maxVisibleDurationMs - 1, 2000), 1000) }
    var maxVisibleDurationMs: Double { max(min(durationMs, 600_000), 1000) }

    func clampVisibleDuration(_ value: Double) -> Double {
        clamp(value, max(min(max(min(durationMs, 600_000), 1000) - 1, 2000), 1000), max(min(durationMs, 600_000), 1000))
    }

    func setVisibleDuration(_ value: Double, anchorMs: Double? = nil) {
        let old = visibleDurationMs
        visibleDurationMs = clampVisibleDuration(value)
        if let anchorMs {
            let fraction = (anchorMs - scrollOffsetMs) / old
            scrollOffsetMs = anchorMs - fraction * visibleDurationMs
        }
        clampScroll()
        UserDefaults.standard.set(visibleDurationMs, forKey: "project-view-timeline-zoom.\(bundleURL.path)")
    }

    func zoomTimeline(in zoomIn: Bool) {
        setVisibleDuration(visibleDurationMs * (zoomIn ? 0.75 : 1.25), anchorMs: currentTimeMs)
    }

    func clampScroll() {
        // The insertable area runs 5 s past the end.
        scrollOffsetMs = clamp(scrollOffsetMs, 0, max(durationMs + 5000 - visibleDurationMs, 0))
    }

    private func followPlayhead() {
        if currentTimeMs > scrollOffsetMs + visibleDurationMs * 0.95 || currentTimeMs < scrollOffsetMs {
            scrollOffsetMs = currentTimeMs - visibleDurationMs * 0.1
            clampScroll()
        }
    }

    // MARK: Sidebar

    func openSidebar(_ root: SidebarRoot) {
        sidebarItem = nil
        sidebarRoot = root
        if layoutType == .hideSidebar { layoutType = .edit }
        if layoutType == .preview { layoutType = .hideTimeline }
    }

    /// Escape: close the item inspector, else go back to General.
    func closeCurrentSidebarPanel() {
        if isAddMaskToolArmed {
            isAddMaskToolArmed = false
        } else if isAddLayoutToolArmed {
            isAddLayoutToolArmed = false
        } else if isAddZoomToolArmed {
            isAddZoomToolArmed = false
        } else if isSplitToolActive {
            isSplitToolActive = false
        } else if sidebarItem != nil {
            sidebarItem = nil
        } else {
            sidebarRoot = .background
        }
    }

    func openZoom(_ id: UUID) {
        sidebarItem = .zoom(id)
        selectedZoomIDs = []
        focusedTrack = "zooms"
    }

    var openZoomID: UUID? {
        if case .zoom(let id) = sidebarItem { return id }
        return nil
    }

    var openSliceID: UUID? {
        if case .slice(let id) = sidebarItem { return id }
        return nil
    }

    /// Clicking a clip opens the slice editor.
    func openSlice(_ id: UUID) {
        sidebarItem = .slice(id)
        selectedZoomIDs = []
    }

    var openMaskID: UUID? {
        if case .mask(let id) = sidebarItem { return id }
        return nil
    }

    func openMask(_ id: UUID) {
        sidebarItem = .mask(id)
        selectedZoomIDs = []
        focusedTrack = "masks"
    }

    /// Where the cursor image is drawn right now (canvas pixels), if visible.
    var cursorAreaRect: Rect2? {
        let snapshot = renderState.current
        let frame = snapshot.track.frame(at: currentTimeMs)
        guard !project.cursor.hide, frame.cursorOpacity > 0.01, let position = frame.cursor else { return nil }
        let layout = snapshot.track.layout
        let asset = cursors.asset(named: frame.cursorName)
        let videoToCanvas = frame.screenRect.width / max(layout.videoSize.width, 1)
        let perPoint = project.recording.pointPixelScale * project.cursor.sizeMultiplier * videoToCanvas * frame.cursorScale
        let tip = layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect)
        return Rect2(
            x: tip.x - asset.hotspotPoints.x * perPoint,
            y: tip.y - asset.hotspotPoints.y * perPoint,
            width: asset.sizePoints.width * perPoint,
            height: asset.sizePoints.height * perPoint
        )
    }

    /// Corner radius of the recording right now (canvas pixels), as the compositor draws it.
    var recordingAreaCornerRadius: Double {
        let snapshot = renderState.current
        let area = snapshot.track.frame(at: currentTimeMs).screenRect
        let zoom = area.width / max(snapshot.track.layout.restScreen.width, 1)
        return min(project.style.cornerRadius * zoom, min(area.width, area.height) / 2)
    }

    /// Where the recording is drawn on the canvas right now (canvas pixels), for overlays.
    var recordingAreaRect: Rect2 {
        renderState.current.track.frame(at: currentTimeMs).screenRect
    }

    // MARK: Masks

    /// Arms the mask tool, or opens the mask under the playhead.
    func armMaskTool(_ type: MaskType) {
        if let mask = project.masks.first(where: { $0.contains(currentSourceTimeMs) }) {
            openMask(mask.id)
            return
        }
        if isAddMaskToolArmed && addMaskType == type {
            isAddMaskToolArmed = false
            return
        }
        addMaskType = type
        isAddMaskToolArmed = true
        isAddZoomToolArmed = false
        isAddLayoutToolArmed = false
        pause()
        sidebarItem = nil
    }

    /// Adds a mask at the playhead: 3 s within the free space, opened and centred.
    func addMask(type: MaskType, bounds: Rect2?) {
        isAddMaskToolArmed = false
        let start = currentSourceTimeMs
        if let existing = project.masks.first(where: { $0.contains(start) }) {
            openMask(existing.id)
            return
        }
        let next = project.sortedMasks.first { $0.startMs > start }?.startMs ?? project.recording.durationMs
        let end = min(start + MaskRange.initialDurationMs, next)
        guard end - start >= MaskRange.minimumDurationMs else {
            toast = "Not enough space in selected timeline position to add a new mask"
            return
        }
        let mask = MaskRange(startMs: start, endMs: end, bounds: bounds.map { [$0] } ?? project.defaultMaskBounds, type: type)
        change { $0.masks.append(mask) }
        openMask(mask.id)
        if !isPlaying { seek(to: project.resolver.sourceToPlayback(start + (end - start) / 2)) }
    }

    /// Mask created from the track (click or drag on the empty area).
    func addMask(startMs: Double, endMs: Double) {
        let mask = MaskRange(startMs: startMs, endMs: endMs, bounds: project.defaultMaskBounds)
        change { $0.masks.append(mask) }
        openMask(mask.id)
        if !isPlaying { seek(to: project.resolver.sourceToPlayback(startMs + (endMs - startMs) / 2)) }
    }

    func updateMask(_ id: UUID, coalesce: String? = nil, _ body: (inout MaskRange) -> Void) {
        change(coalesce: coalesce) { project in
            guard let index = project.masks.firstIndex(where: { $0.id == id }) else { return }
            body(&project.masks[index])
        }
    }

    func freeMaskRange(around timeMs: Double, excluding id: UUID? = nil) -> (start: Double, end: Double)? {
        let others = project.sortedMasks.filter { $0.id != id }
        if others.contains(where: { $0.contains(timeMs) && $0.endMs > timeMs }) { return nil }
        let start = others.last(where: { $0.endMs <= timeMs })?.endMs ?? 0
        let end = others.first(where: { $0.startMs >= timeMs })?.startMs ?? project.recording.durationMs
        return (start, end)
    }

    func moveMask(_ id: UUID, toStart start: Double) {
        guard let mask = project.masks.first(where: { $0.id == id }) else { return }
        let others = project.sortedMasks.filter { $0.id != id }
        let lower = others.last(where: { $0.endMs <= mask.startMs + 0.5 })?.endMs ?? 0
        let upper = others.first(where: { $0.startMs >= mask.endMs - 0.5 })?.startMs ?? project.recording.durationMs
        let newStart = clamp(start, lower, upper - mask.durationMs)
        updateMask(id, coalesce: "drag-\(id)") {
            $0.startMs = newStart
            $0.endMs = newStart + mask.durationMs
        }
    }

    func resizeMask(_ id: UUID, leading: Bool, to time: Double) {
        guard let mask = project.masks.first(where: { $0.id == id }) else { return }
        let others = project.sortedMasks.filter { $0.id != id }
        let minimum = MaskRange.minimumDurationMs
        updateMask(id, coalesce: "resize-\(id)") {
            if leading {
                let lower = others.last(where: { $0.endMs <= mask.startMs + 0.5 })?.endMs ?? 0
                $0.startMs = clamp(time, lower, mask.endMs - minimum)
            } else {
                let upper = others.first(where: { $0.startMs >= mask.endMs - 0.5 })?.startMs ?? project.recording.durationMs
                $0.endMs = clamp(time, mask.startMs + minimum, upper)
            }
        }
    }

    func splitMask(_ id: UUID, at timeMs: Double) {
        guard let mask = project.masks.first(where: { $0.id == id }) else { return }
        let minimum = MaskRange.minimumDurationMs
        guard timeMs - mask.startMs >= minimum, mask.endMs - timeMs >= minimum else {
            NSSound.beep()
            return
        }
        var second = mask
        second.id = UUID()
        second.startMs = timeMs
        change { project in
            guard let index = project.masks.firstIndex(where: { $0.id == id }) else { return }
            project.masks[index].endMs = timeMs
            project.masks.append(second)
        }
    }

    func removeMasks(_ ids: Set<UUID>) {
        change { $0.masks.removeAll { ids.contains($0.id) } }
    }

    func setAllMasks(disabled: Bool) {
        change { project in
            for index in project.masks.indices { project.masks[index].isDisabled = disabled }
        }
    }

    /// "Apply to all masks" for the highlight opacity.
    func applyHighlightOpacityToAllMasks(from id: UUID) {
        guard let opacity = project.masks.first(where: { $0.id == id })?.highlightMaskOpacity else { return }
        change { project in
            for index in project.masks.indices { project.masks[index].highlightMaskOpacity = opacity }
        }
        toast = "Highlight mask opacity applied to all masks"
    }

    /// Recording time at the playhead.
    var currentSourceTimeMs: Double { project.resolver.playbackToSource(currentTimeMs) }

    // MARK: Clips

    /// Splits the clip at a playback time; "The part you want to cut is too short" otherwise.
    func splitSlice(atPlayback playbackMs: Double) {
        let source = project.resolver.playbackToSource(playbackMs)
        guard project.canSplitSlice(at: source) else {
            toast = "The part you want to cut is too short"
            return
        }
        change { $0.splitSlice(at: source) }
    }

    /// Trim by dragging an edge (playback time), moving the playhead to the trimmed edge.
    func trimSlice(_ id: UUID, edge: Project.SliceEdge, toSource sourceMs: Double) {
        change(coalesce: "trim-\(id)") { project in
            switch edge {
            case .start: project.updateSlice(id, sourceStartMs: sourceMs)
            case .end: project.updateSlice(id, sourceEndMs: sourceMs)
            }
        }
        guard let slice = project.slices.first(where: { $0.id == id }) else { return }
        seek(to: project.resolver.sourceToPlayback(edge == .start ? slice.sourceStartMs : slice.sourceEndMs))
    }

    func updateSlice(_ id: UUID, coalesce: String? = nil, _ body: (inout Slice) -> Void) {
        change(coalesce: coalesce) { project in
            guard let index = project.slices.firstIndex(where: { $0.id == id }) else { return }
            body(&project.slices[index])
        }
    }

    func setSliceSpeed(_ id: UUID, _ speed: Double) {
        updateSlice(id) { $0.timeScale = 1 / speed }
    }

    /// "Apply speed to all slices".
    func applySpeedToAllSlices(from id: UUID) {
        guard let scale = project.slices.first(where: { $0.id == id })?.timeScale else { return }
        change { project in
            for index in project.slices.indices { project.slices[index].timeScale = scale }
        }
    }

    func canApplySpeedToAll(from id: UUID) -> Bool {
        guard let scale = project.slices.first(where: { $0.id == id })?.timeScale else { return false }
        return project.slices.contains { $0.timeScale != scale }
    }

    func mergeSlice(_ id: UUID, with neighbour: Project.SliceNeighbour) {
        change { $0.mergeSlice(id, with: neighbour) }
    }

    func removeSlice(_ id: UUID) {
        change { $0.removeSlice(id) }
    }

    func removeSliceTrim(_ id: UUID, edge: Project.SliceEdge? = nil) {
        change { $0.removeSliceTrim(id, edge: edge) }
    }

    /// "Reset trims and cuts for all slices", after confirmation.
    func resetAllSlices() {
        let alert = NSAlert()
        alert.messageText = "Reset trims and cuts for all slices"
        alert.informativeText = "Are you sure you want to reset trims and cuts for all slices"
        alert.addButton(withTitle: "Reset all cuts and trims for all slices")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        change { $0.resetSlices() }
    }

    // MARK: Typing suggestions

    /// "recording-typing-suggestion-preferred-speed-v2", 1.5–8, default 3.
    var preferredTypingSpeed: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "recording-typing-suggestion-preferred-speed-v2")
            return stored > 0 ? stored : 3
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "recording-typing-suggestion-preferred-speed-v2")
            objectWillChange.send()
        }
    }

    func applyTypingSuggestion(_ range: TimeRange) {
        let speed = preferredTypingSpeed
        change { $0.applyTypingSuggestion(range, speed: speed) }
    }

    func applyAllTypingSuggestions() {
        let speed = preferredTypingSpeed
        change { project in
            for range in project.pendingTypingSuggestions { project.applyTypingSuggestion(range, speed: speed) }
        }
    }

    func removeTypingSuggestion(_ range: TimeRange) {
        change { $0.resolvedTypingSuggestionsMs.append(range.startMs) }
    }

    // MARK: Zooms

    var sortedZooms: [ZoomRange] { project.zooms.sorted { $0.startMs < $1.startMs } }

    /// Free time range around `timeMs` between neighbouring zooms (excluding `id`).
    func freeRange(around timeMs: Double, excluding id: UUID? = nil) -> (start: Double, end: Double)? {
        let others = sortedZooms.filter { $0.id != id }
        if others.contains(where: { $0.contains(timeMs) && $0.endMs > timeMs }) { return nil }
        let start = others.last(where: { $0.endMs <= timeMs })?.endMs ?? 0
        let end = others.first(where: { $0.startMs >= timeMs })?.startMs ?? project.recording.durationMs
        return (start, end)
    }

    /// Adds a zoom, constrained to the free gap around `startMs`.
    @discardableResult
    func addZoom(startMs: Double, durationMs requested: Double = ZoomRange.initialDurationMs, manualTarget: Vec2? = nil) -> UUID? {
        guard let gap = freeRange(around: startMs + 1) else { return nil }
        let start = clamp(startMs, gap.start, gap.end)
        let end = min(start + requested, gap.end)
        guard end - start >= ZoomRange.minimumDurationMs else { return nil }
        let zoom = ZoomRange(
            startMs: start,
            endMs: end,
            scale: preferences.defaultZoomLevel ?? 2,
            mode: manualTarget == nil ? .auto : .manual,
            manualTarget: manualTarget ?? .center01
        )
        change { $0.zooms.append(zoom) }
        UserDefaults.standard.set(true, forKey: "onboarding.creating-zoom")
        openZoom(zoom.id)
        return zoom.id
    }

    func updateZoom(_ id: UUID, coalesce: String? = nil, _ body: (inout ZoomRange) -> Void) {
        change(coalesce: coalesce) { project in
            guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            body(&project.zooms[index])
            project.zooms[index].isGenerated = false
        }
    }

    /// Drag-move, clamped to the neighbours and the timeline bounds.
    func moveZoom(_ id: UUID, toStart start: Double) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let others = sortedZooms.filter { $0.id != id }
        let lower = others.last(where: { $0.endMs <= zoom.startMs + 0.5 })?.endMs ?? 0
        let upper = others.first(where: { $0.startMs >= zoom.endMs - 0.5 })?.startMs ?? project.recording.durationMs
        let newStart = clamp(start, lower, upper - zoom.durationMs)
        updateZoom(id, coalesce: "drag-\(id)") {
            $0.startMs = newStart
            $0.endMs = newStart + zoom.durationMs
        }
    }

    func resizeZoom(_ id: UUID, leading: Bool, to time: Double) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let others = sortedZooms.filter { $0.id != id }
        let minimum = ZoomRange.minimumDurationMs
        updateZoom(id, coalesce: "resize-\(id)") {
            if leading {
                let lower = others.last(where: { $0.endMs <= zoom.startMs + 0.5 })?.endMs ?? 0
                $0.startMs = clamp(time, lower, zoom.endMs - minimum)
            } else {
                let upper = others.first(where: { $0.startMs >= zoom.endMs - 0.5 })?.startMs ?? project.recording.durationMs
                $0.endMs = clamp(time, zoom.startMs + minimum, upper)
            }
        }
    }

    func removeZooms(_ ids: Set<UUID>) {
        change { $0.zooms.removeAll { ids.contains($0.id) } }
    }

    func duplicateZoom(_ id: UUID) {
        guard let zoom = project.zooms.first(where: { $0.id == id }), let gap = freeRange(around: zoom.endMs + 1) else { return }
        let end = min(zoom.endMs + zoom.durationMs, gap.end)
        guard end - zoom.endMs >= ZoomRange.minimumDurationMs else { return }
        var copy = zoom
        copy.id = UUID()
        copy.startMs = zoom.endMs
        copy.endMs = end
        copy.isGenerated = false
        change { $0.zooms.append(copy) }
        openZoom(copy.id)
    }

    /// Splits a zoom at `timeMs` (the playhead, or the split tool's beam).
    func splitZoom(_ id: UUID, at timeMs: Double) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let minimum = ZoomRange.minimumDurationMs
        guard timeMs - zoom.startMs >= minimum, zoom.endMs - timeMs >= minimum else {
            NSSound.beep()
            return
        }
        var second = zoom
        second.id = UUID()
        second.startMs = timeMs
        second.isGenerated = false
        change { project in
            guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            project.zooms[index].endMs = timeMs
            project.zooms[index].isGenerated = false
            project.zooms.append(second)
        }
    }

    func setAllZooms(disabled: Bool) {
        change { project in
            for index in project.zooms.indices { project.zooms[index].isDisabled = disabled }
        }
    }

    func applyZoomLevelToAll(from id: UUID) {
        guard let level = project.zooms.first(where: { $0.id == id })?.scale else { return }
        change { project in
            for index in project.zooms.indices { project.zooms[index].scale = level }
        }
    }

    /// "Restore default zoom ranges": regenerate automatic zooms from the clicks.
    func restoreDefaultZooms() {
        change { project in
            project.zooms.removeAll()
            project.autoZoom.isEnabled = true
            project.regenerateAutomaticZooms()
        }
    }

    // MARK: Project file

    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard preferences.autoSaveProject else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try ProjectStore.save(project, to: bundleURL)
            isDirty = false
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Renames the project folder. Forbidden characters are stripped.
    func rename(to rawName: String) {
        let forbidden = CharacterSet(charactersIn: "\\/*?\"<>|%¿:")
        let cleaned = rawName.components(separatedBy: forbidden).joined().trimmingCharacters(in: .whitespaces)
        if cleaned != rawName.trimmingCharacters(in: .whitespaces) {
            Dialogs.info(title: "Filename contains forbidden characters", message: "They were removed from the project name.")
        }
        let name = cleaned.isEmpty ? "Recording" : cleaned
        guard name != projectName else { return }
        let target = bundleURL.deletingLastPathComponent().appendingPathComponent("\(name).\(ProjectStore.fileExtension)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            Dialogs.error("A project named \"\(name)\" already exists in this folder.")
            return
        }
        do {
            saveNow()
            try FileManager.default.moveItem(at: bundleURL, to: target)
            bundleURL = target
            objectWillChange.send()
            Task { await rebuildComposition() }
        } catch {
            Dialogs.error("Could not rename the project: \(error.localizedDescription)")
        }
    }

    /// "Remove project": moves the project folder to the Trash.
    func deleteProject() -> Bool {
        guard Dialogs.confirm(title: "Delete this project?", message: "This action cannot be undone.", confirm: "Delete", destructive: true) else { return false }
        pause()
        do {
            try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
            isDirty = false
            return true
        } catch {
            Dialogs.error("Could not delete the project: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Export & frame

    func openExportPicker() {
        guard !exports.isExporting else { return }
        pause()
        exports.openPicker()
    }

    /// "Copy current frame as image".
    func copyCurrentFrame() {
        guard let composition = player.currentItem?.videoComposition, let asset = player.currentItem?.asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: currentTimeMs / 1000, preferredTimescale: 600)
        Task {
            guard let image = try? await generator.image(at: time).image else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
        }
    }

    func tearDown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        autosaveTask?.cancel()
    }
}
