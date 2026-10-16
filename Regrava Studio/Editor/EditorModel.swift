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
    @Published private(set) var isPlaying = false
    /// `playback.defaultRate`: 0.25…8.
    @Published var playbackRate: Double = 1

    // View state
    @Published var layoutType: EditorLayoutType = .edit
    @Published var sidebarRoot: SidebarRoot = .background
    @Published var sidebarItem: SidebarItem?
    @Published var selectedZoomIDs: Set<UUID> = []
    /// Zoom add tool armed from the add-tools rail.
    @Published var isAddZoomToolArmed = false
    @Published var isSplitToolActive = false
    /// Visible timeline duration (zoom level of the timeline).
    @Published var visibleDurationMs: Double = 30_000
    /// Left edge of the visible timeline range.
    @Published var scrollOffsetMs: Double = 0
    /// "zooms" track is focused by default; nil = none.
    @Published var focusedTrack: String? = "zooms"
    @Published var errorMessage: String?

    private let cursors: CursorLibrary
    private let renderState: RenderState
    private var baseComposition: AVMutableVideoComposition?
    private var compositionCanvas: Size2?
    private var compositionOutput: Size2?
    private var timeObserver: Any?
    private var refreshTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastCoalesceKey: String?
    private var lastChangeAt = Date.distantPast
    private var isScrubbing = false
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
        project = updated
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if case .zoom(let id) = sidebarItem, !project.zooms.contains(where: { $0.id == id }) { sidebarItem = nil }
        selectedZoomIDs = selectedZoomIDs.filter { id in project.zooms.contains { $0.id == id } }
        isDirty = true
        scheduleAutosave()
        if canvasChanged || slicesChanged {
            Task { await rebuildComposition(replacingItem: slicesChanged) }
        } else {
            scheduleRefresh()
        }
    }

    // MARK: Rendering

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
            let asset = try await PlaybackComposition.make(asset: AVURLAsset(url: videoURL), slices: project.slices)
            let output = previewOutputSize
            let composition = try await CompositionFactory.make(asset: asset, state: renderState, canvas: project.canvasSize, outputSize: output)
            baseComposition = composition
            compositionCanvas = project.canvasSize
            compositionOutput = output
            if let item = player.currentItem, !replacingItem {
                item.videoComposition = composition
            } else {
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .spectral
                item.videoComposition = composition
                player.replaceCurrentItem(with: item)
            }
            if !isPlaying { seek(to: min(currentTimeMs, durationMs)) }
        } catch {
            errorMessage = "Could not load the recording: \(error.localizedDescription)"
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let project = self.project
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
            // Re-assigning the composition drops cached frames.
            if let base = self.baseComposition, let item = self.player.currentItem,
               let copy = base.mutableCopy() as? AVMutableVideoComposition {
                item.videoComposition = copy
                if !self.isPlaying { self.seek(to: self.isScrubbing ? self.scrubTimeMs : self.currentTimeMs, moveHead: false) }
            }
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
        clamp(value, max(min(max(min(project.recording.durationMs, 600_000), 1000) - 1, 2000), 1000), max(min(project.recording.durationMs, 600_000), 1000))
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
        if isAddZoomToolArmed {
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

    // MARK: Zooms

    var sortedZooms: [ZoomRange] { project.zooms.sorted { $0.startMs < $1.startMs } }

    /// Free time range around `timeMs` between neighbouring zooms (excluding `id`).
    func freeRange(around timeMs: Double, excluding id: UUID? = nil) -> (start: Double, end: Double)? {
        let others = sortedZooms.filter { $0.id != id }
        if others.contains(where: { $0.contains(timeMs) && $0.endMs > timeMs }) { return nil }
        let start = others.last(where: { $0.endMs <= timeMs })?.endMs ?? 0
        let end = others.first(where: { $0.startMs >= timeMs })?.startMs ?? durationMs
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
        let upper = others.first(where: { $0.startMs >= zoom.endMs - 0.5 })?.startMs ?? durationMs
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
                let upper = others.first(where: { $0.startMs >= zoom.endMs - 0.5 })?.startMs ?? durationMs
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
