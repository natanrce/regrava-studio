@preconcurrency import AVFoundation
import MediaPlayer
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
final class PlaybackClock: ObservableObject {
    @Published var currentTimeMs: Double = 0
}

final class TimelineViewport: ObservableObject {
    @Published var visibleDurationMs: Double = 30_000
    @Published var scrollOffsetMs: Double = 0
}

final class EditorModel: ObservableObject {
    private(set) var bundleURL: URL
    let player = AVPlayer()
    let exports = ExportController()
    private let preferences = Preferences.shared

    @Published private(set) var project: Project {
        didSet {
            if project.slices != oldValue.slices { resolver = project.resolver }
            audioPlayer.projectDidChange()
        }
    }
    /// `project.resolver`, rebuilt only when the clips change (read every frame).
    private(set) var resolver: TimeResolver
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // Playback
    /// The playhead, published on its own object: only views that show time redraw with it
    /// (it changes every frame while playing).
    let clock = PlaybackClock()
    private(set) var currentTimeMs: Double {
        get { clock.currentTimeMs }
        set { clock.currentTimeMs = newValue }
    }
    @Published private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            audioPlayer.playbackDidChange()
            followSuspended = false
            updateRenderQuality()
            updatePlainScreen()
        }
    }
    /// `playback.defaultRate`: 0.25…8.
    @Published var playbackRate: Double = 1 {
        didSet { audioPlayer.playbackDidChange() }
    }
    /// J/L speed (`shuttleRate`), cleared by any pause.
    @Published private(set) var shuttleRate: Double? {
        didSet { audioPlayer.playbackDidChange() }
    }
    var effectiveRate: Double { shuttleRate ?? playbackRate }
    /// A wheel scroll during playback stops following the playhead until playback stops.
    var followSuspended = false
    /// Rates the player cannot play itself (reverse, fast) run on a timer of seeks, like a
    /// clock that moves `deltaMs * rate` each frame.
    private var manualTimer: Timer?
    private var manualLast: CFTimeInterval = 0
    private var manualRate: Double = 0

    // View state
    @Published var layoutType: EditorLayoutType = .edit {
        didSet { if oldValue.showsSidebar != layoutType.showsSidebar { refocusOpenItem() } }
    }
    @Published var sidebarRoot: SidebarRoot = .background
    @Published var sidebarItem: SidebarItem? {
        didSet {
            updatePlainScreen()
            if oldValue != sidebarItem { refocusOpenItem() }
        }
    }
    /// ⌘-clicked timeline items, all of one kind.
    @Published var selectedTargets: [EditorTarget] = []
    /// Selection and focused targets (hover changes are not published: only actions read them).
    var targetStack = ActionTargetStack<EditorTarget, EditorTarget.Kind>(kind: \.kind)
    var openItemFocusToken: Int?
    /// The copied zoom, layout or mask (⌘C / Cut to clipboard), pasted with ⌘V.
    var itemClipboard: ItemClipboard?
    /// The command menu's sessions (⌘K, or a shortcut's sub-actions).
    let commandMenu = CommandMenuController()
    /// The space the preview may use under its layout controls, in points (set by the preview).
    private(set) var previewAvailableSpace: CGSize?
    /// Pixels per point of the screen showing the preview (set by the preview).
    private(set) var previewBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    /// Microphone renders under way, 0…1 (`media.audioRenderState` partial).
    @Published var microphoneRenderProgress: [MicrophoneAudioPreset: Double] = [:]
    /// Renders paused by re-clicking their option.
    @Published var pausedMicrophoneRenders: Set<MicrophoneAudioPreset> = []
    private var microphoneRenderTasks: [MicrophoneAudioPreset: Task<Void, Never>] = [:]
    var defaultZoomLevelTask: Task<Void, Never>?
    /// Zoom add tool armed from the add-tools rail.
    @Published var isAddZoomToolArmed = false {
        didSet { updatePlainScreen() }
    }
    /// Which zoom the add tool places (`view.addZoomPresentation`).
    @Published var addZoomPresentation = ZoomPresentation.screen
    /// Mask add tool (`activeAddTool = "mask"`, `addMaskType`).
    @Published var isAddMaskToolArmed = false {
        didSet { updatePlainScreen() }
    }
    @Published var addMaskType: MaskType = .sensitiveData
    /// Layout add tool (`activeAddTool = "layout"`); only camera overlay arms it.
    @Published var isAddLayoutToolArmed = false {
        didSet { updatePlainScreen() }
    }
    /// The microphone transcript (`transcripts/microphone-session-0.json`), nil until generated.
    @Published var transcript: SessionTranscript? {
        didSet {
            clientTranscriptCache = nil
            transcriptTokensCache = nil
            visibleCaptionWordsCache = nil
        }
    }
    struct CaptionWordsKey: Equatable {
        var resolver: TimeResolver
        var showSoundLabels: Bool
    }
    private var visibleCaptionWordsCache: (key: CaptionWordsKey, value: Bool)?
    /// `clientTranscript` and `transcriptTokens`, kept until the transcript changes.
    var clientTranscriptCache: [TranscriptWord]?
    var transcriptTokensCache: [TranscriptToken]?
    /// "Generating transcript" task running.
    @Published var isGeneratingTranscript = false
    /// Last layout type chosen from the add tools (`addLayoutType`), used by ⌃L.
    @Published var addLayoutType: CameraLayoutType = .cameraOverlay
    @Published var isSplitToolActive = false
    /// The timeline's scroll and zoom, published on their own object: only the timeline redraws
    /// while they change (scroll and pinch fire for every trackpad event).
    let viewport = TimelineViewport()
    /// Background tasks shown by the toolbar's spinner (`view.tasks`).
    let tasks = BackgroundTasks()
    /// Audio waveforms drawn in the clips.
    let waveforms = TimelineWaveforms()
    /// The editor's audio: playback, scrubbing and volume change previews.
    let audioPlayer = ProjectAudioPlayer()
    /// Visible timeline duration (zoom level of the timeline).
    var visibleDurationMs: Double {
        get { viewport.visibleDurationMs }
        set { viewport.visibleDurationMs = newValue }
    }
    /// Left edge of the visible timeline range.
    var scrollOffsetMs: Double {
        get { viewport.scrollOffsetMs }
        set { viewport.scrollOffsetMs = newValue }
    }
    /// "zooms" track is focused by default; nil = none.
    @Published var focusedTrack: String? = "zooms"
    @Published var errorMessage: String?
    /// The running transcript audition ("Play" in the transcript bar).
    var auditionTask: Task<Void, Never>?
    /// The one toast shown at the bottom of the editor; a new one replaces it.
    @Published var toast: EditorToast?

    /// Shows a toast for `durationMs` (5 s unless a call says otherwise).
    func showToast(_ message: String, title: String? = nil, kind: EditorToast.Kind = .info, durationMs: Double = EditorToast.defaultDurationMs) {
        toast = EditorToast(kind: kind, title: title, message: message, durationMs: durationMs)
    }

    /// A failed action shows its error as an error toast.
    func showError(_ error: Error) {
        let message = error.localizedDescription
        showToast(message.isEmpty ? "Unknown error" : message, kind: .error)
    }

    func dismissToast(_ id: UUID? = nil) {
        if id == nil || toast?.id == id { toast = nil }
    }

    /// When the preview-size warning last showed, across every editor window.
    private static var previewSizeWarningShownAt: Date?

    /// A larger preview warns about playback performance, at most once every 5 minutes.
    func warnAboutLargerPreview() {
        let now = Date()
        if let shown = Self.previewSizeWarningShownAt, now.timeIntervalSince(shown) < 5 * 60 { return }
        Self.previewSizeWarningShownAt = now
        showToast("Increasing the playback preview size may affect preview playback performance")
    }

    private var cursors: CursorLibrary
    private let renderState: RenderState
    private var baseConfiguration: AVVideoComposition.Configuration?
    private var timeObserver: Any?
    private var refreshTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    /// Transcript edits share the project's history (`project.history.update(client, …)`).
    private struct HistoryEntry {
        var project: Project
        var transcript: SessionTranscript?
    }

    private var history = UndoHistory<HistoryEntry>()
    private var historyTimer: Task<Void, Never>?
    private var transcriptSaveTask: Task<Void, Never>?
    private var isScrubbing = false {
        didSet {
            guard oldValue != isScrubbing else { return }
            if !isScrubbing { scrubDisplay.hide() }
            updateRenderQuality()
        }
    }
    /// Hover scrubbing shows frames from native scrubbers over the player, never seeking it.
    let scrubDisplay = ScrubDisplay()
    private var scrubPreview: ScrubPreview?
    private var cancellables: Set<AnyCancellable> = []

    init(bundleURL: URL, project: Project) {
        self.bundleURL = bundleURL
        self.project = project
        resolver = project.resolver
        cursors = CursorLibrary.make(project: project, bundle: bundleURL)
        renderState = RenderState(project: project, cursors: cursors, assetsDirectory: bundleURL, outputSize: Self.previewOutputSize(
            canvas: project.canvasSize, display: Self.previewDisplaySize(canvas: project.canvasSize, available: nil, maxHeight: Self.previewMaxHeight),
            backingScale: NSScreen.main?.backingScaleFactor ?? 2, resolution: Preferences.shared.playbackPreviewResolution
        ))
        transcript = SessionTranscript.load(bundle: bundleURL)
        // The editor and its project are targets while the window is open.
        targetStack.focus(.editor)
        targetStack.focus(.project)
        let saved = UserDefaults.standard.double(forKey: "project-view-timeline-zoom.\(bundleURL.path)")
        visibleDurationMs = clampVisibleDuration(saved > 0 ? saved : 30_000)
        // Each publisher sends its current value first; only later changes rebuild.
        Publishers.Merge(preferences.$playbackPreviewResolution.dropFirst().map { _ in () }, preferences.$playbackPreviewMaxHeight.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { Task { await self?.rebuildComposition() } } }
            .store(in: &cancellables)
        commandMenu.rootActions = { [weak self] in self?.actionCatalog.all ?? [] }
        // The analysis demand: the head's source time once it rests for 500 ms, none while an
        // export runs.
        clock.$currentTimeMs.combineLatest(exports.$job.map { $0 != nil })
            .map { [weak self] timeMs, isExporting -> Double? in
                guard let self, !isExporting else { return nil }
                return self.resolver.playbackToSource(timeMs)
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(Self.analysisDemandDelayMs), scheduler: RunLoop.main)
            .sink { [weak self] in self?.setAnalysisDemand($0) }
            .store(in: &cancellables)
    }

    static let analysisDemandDelayMs = 500
    /// The source moment the editor looks at (preview priority): a sensitive data scan starts
    /// with the chunks nearest it.
    private func setAnalysisDemand(_ sourceMs: Double?) {
        SensitiveDataScans.setDemand(bundle: bundleURL, requesterId: "editor", recordingTimeMs: sourceMs, priority: .preview)
    }

    /// Playback duration (clips sped up, slowed down or cut).
    var durationMs: Double { resolver.playbackDurationMs }
    var projectName: String { bundleURL.deletingPathExtension().lastPathComponent }
    var videoURL: URL { ProjectStore.videoURL(bundle: bundleURL, project: project) }

    func prepare() async {
        await rebuildComposition()
        updateFaceTracking()
        updateSensitiveDataScan()
        updateCameraMatte()
        updateSilence()
        syncMicrophoneRenders()
        updateHoverDetection()
        player.actionAtItemEnd = .pause
        exports.onToast = { [weak self] in self?.showToast($0, kind: .error) }
        exports.tasks = tasks
        exports.onWillStart = { [weak self] in self?.cancelSpeechModelRenders() }
        registerMediaKeys()
        // The mix plays through the audio engine; the player only shows the video.
        player.volume = 0
        audioPlayer.start(editor: self)
        player.publisher(for: \.isMuted)
            .sink { [weak self] muted in self?.audioPlayer.setMuted(muted) }
            .store(in: &cancellables)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.manualTimer == nil else { return }
                // The player stopped by itself: the end (or the start in reverse).
                if self.isPlaying && self.player.rate == 0 { self.reachedEnd() }
                if !self.isScrubbing || self.isPlaying {
                    self.currentTimeMs = time.seconds * 1000
                    if self.isPlaying { self.followPlayhead() }
                }
            }
        }
    }

    // MARK: Microphone modes

    /// Modes the picker offers: the speech-model ones only where those models run.
    static var supportedMicrophonePresets: [MicrophoneAudioPreset] {
        // The enum order: Standard, Loud, Noise reduction, Podcast, Off.
        [.voice, .loud] + (SpeechModels.isAvailable ? [.noiseReduction, .podcast] : []) + [.channelFix]
    }

    /// Muted: every render pauses. Otherwise Standard always renders first (the fallback), then
    /// the chosen mode.
    func syncMicrophoneRenders() {
        let audio = project.audio
        guard let index = project.recording.audioSources.firstIndex(of: .microphone), !audio.muteMicrophone else {
            for task in microphoneRenderTasks.values { task.cancel() }
            microphoneRenderTasks = [:]
            return
        }
        var wanted: [MicrophoneAudioPreset] = [.voice]
        let preset = audio.microphoneAudioPreset
        if preset != .voice, Self.supportedMicrophonePresets.contains(preset), !pausedMicrophoneRenders.contains(preset) { wanted.append(preset) }
        for (running, task) in microphoneRenderTasks where !wanted.contains(running) {
            task.cancel()
            microphoneRenderTasks[running] = nil
        }
        // One render at a time, in order.
        guard microphoneRenderTasks.isEmpty,
              let next = wanted.first(where: { MicrophoneRenderer.readyURL(bundle: bundleURL, preset: $0) == nil }) else { return }
        let recording = videoURL, bundle = bundleURL
        microphoneRenderProgress[next] = 0
        // "Preparing audio" shows after 800 ms, the other modes after 100 ms.
        let taskID = "microphone-render-\(next.rawValue)"
        tasks.register(taskID, name: next.taskLabel, showAfterMs: next == .voice || next == .channelFix ? 800 : 100, progress01: 0)
        microphoneRenderTasks[next] = Task { [weak self] in
            defer { self?.tasks.finish(taskID) }
            do {
                try await MicrophoneRenderer.render(recording: recording, microphoneTrackIndex: index, preset: next, bundle: bundle) { value in
                    Task { @MainActor in
                        self?.microphoneRenderProgress[next] = value
                        self?.tasks.update(taskID, progress01: value)
                    }
                }
                guard let self else { return }
                self.microphoneRenderProgress[next] = nil
                self.microphoneRenderTasks[next] = nil
                if next == self.project.audio.microphoneAudioPreset || next == .voice { await self.rebuildComposition(replacingItem: true) }
                self.syncMicrophoneRenders()
            } catch {
                guard let self else { return }
                self.microphoneRenderTasks[next] = nil
                if !(error is CancellationError) { self.microphoneRenderProgress[next] = nil }
            }
        }
    }

    /// Starting an export stops the microphone renders that run a speech model.
    func cancelSpeechModelRenders() {
        for (preset, task) in microphoneRenderTasks where preset.needsSpeechModels { task.cancel() }
    }

    /// Re-clicking the chosen non-Standard mode pauses or resumes its render.
    func toggleMicrophoneRender(_ preset: MicrophoneAudioPreset) {
        guard preset != .voice, MicrophoneRenderer.readyURL(bundle: bundleURL, preset: preset) == nil else { return }
        if pausedMicrophoneRenders.contains(preset) { pausedMicrophoneRenders.remove(preset) } else {
            pausedMicrophoneRenders.insert(preset)
            microphoneRenderTasks[preset]?.cancel()
            microphoneRenderTasks[preset] = nil
        }
        syncMicrophoneRenders()
    }

    // MARK: Changes & history

    /// Applies a change with undo support. Changes less than 100 ms apart, from any source,
    /// form a single undo step (for up to 5 s).
    func change(_ body: (inout Project) -> Void) {
        var updated = project
        body(&updated)
        guard updated != project else { return }
        recordHistory()
        apply(updated)
    }

    /// An undoable transcript edit, optionally with project changes (cuts) in the same step.
    func changeTranscript(_ words: [TranscriptWord]?, project body: ((inout Project) -> Void)? = nil) {
        var updatedProject = project
        body?(&updatedProject)
        var updatedTranscript = transcript
        if let words, updatedTranscript != nil { updatedTranscript!.transcript = words }
        guard updatedProject != project || updatedTranscript != transcript else { return }
        recordHistory()
        applyTranscript(updatedTranscript)
        if updatedProject != project { apply(updatedProject) }
    }

    /// Published only when they change: every set redraws the editor.
    private func updateHistoryFlags() {
        if canUndo != history.canUndo { canUndo = history.canUndo }
        if canRedo != history.canRedo { canRedo = history.canRedo }
    }

    private static var historyClockMs: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    private func recordHistory() {
        history.record(changingFrom: HistoryEntry(project: project, transcript: transcript), at: Self.historyClockMs)
        updateHistoryFlags()
        armHistoryTimer()
    }

    /// Runs the buffer's timer until it is no longer armed.
    private func armHistoryTimer() {
        historyTimer?.cancel()
        guard let deadline = history.debouncer.deadline else { return }
        historyTimer = Task { [weak self] in
            let delay = max(0, deadline - Self.historyClockMs)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            guard !Task.isCancelled, let self else { return }
            self.history.timerFired(at: max(deadline, Self.historyClockMs))
            self.updateHistoryFlags()
            self.armHistoryTimer()
        }
    }

    /// Undo and redo keep the playhead on its recording frame (`stickyAction`).
    func undo() {
        stickyPlayhead {
            guard let previous = history.undo(current: HistoryEntry(project: project, transcript: transcript)) else { return }
            restore(previous)
        }
    }

    func redo() {
        stickyPlayhead {
            guard let next = history.redo(current: HistoryEntry(project: project, transcript: transcript)) else { return }
            restore(next)
        }
    }

    private func restore(_ entry: HistoryEntry) {
        applyTranscript(entry.transcript)
        apply(entry.project)
        updateHistoryFlags()
    }

    /// Edited transcripts are saved 800 ms after the last change.
    private func applyTranscript(_ updated: SessionTranscript?) {
        guard updated != transcript else { return }
        transcript = updated
        updateHistoryFlags()
        scheduleRefresh()
        transcriptSaveTask?.cancel()
        guard let updated else { return }
        let bundle = bundleURL
        transcriptSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            try? updated.save(bundle: bundle)
            // Captions draw the saved transcript.
            self?.scheduleRefresh()
        }
    }

    private func apply(_ updated: Project) {
        let canvasChanged = updated.canvasSize != project.canvasSize
        let slicesChanged = updated.slices != project.slices
        let backgroundChanged = updated.audio.backgroundAudioFileName != project.audio.backgroundAudioFileName
            || updated.audio.muteBackgroundAudio != project.audio.muteBackgroundAudio
            || (updated.audio.backgroundAudioVolume > 0) != (project.audio.backgroundAudioVolume > 0)
        // Click sounds are tracks of the composition: a new set or turning the volume on or off.
        let clicksChanged = updated.audio.clickSoundEffect != project.audio.clickSoundEffect
            || (updated.audio.clickSoundEffectVolume > 0) != (project.audio.clickSoundEffectVolume > 0)
        let audioChanged = updated.audio != project.audio
        let cameraDelayChanged = updated.camera.delayAdjustmentMs != project.camera.delayAdjustmentMs
        let faceTrackingChanged = updated.camera.enableFaceTracking != project.camera.enableFaceTracking
        let silenceChanged = updated.camera.hideDuringSilenceMs != project.camera.hideDuringSilenceMs
        let cursorStyleChanged = updated.cursor.set != project.cursor.set
        let oldFollowsHovers = project.cursor.followRecordedPositionOnHover, oldSpringIsNil = project.animation.mouseSpring == nil
        let oldProcessing = project.processing
        let micModeChanged = updated.audio.microphoneAudioPreset != project.audio.microphoneAudioPreset
            || updated.audio.muteMicrophone != project.audio.muteMicrophone
        // Frames never depend on the audio settings.
        var updatedVideo = updated
        updatedVideo.audio = project.audio
        let onlyAudioChanged = audioChanged && updatedVideo == project
        project = updated
        // A new cursor style means new images (picked before the next snapshot is made).
        if cursorStyleChanged { cursors = CursorLibrary.make(project: project, bundle: bundleURL) }
        updateHistoryFlags()
        if case .zoom(let id) = sidebarItem, !project.zooms.contains(where: { $0.id == id }) { sidebarItem = nil }
        if case .slice(let id) = sidebarItem, !project.slices.contains(where: { $0.id == id }) { sidebarItem = nil }
        if case .mask(let id) = sidebarItem, !project.masks.contains(where: { $0.id == id }) { sidebarItem = nil }
        if case .layout(let id) = sidebarItem, !project.cameraLayouts.contains(where: { $0.id == id }) { sidebarItem = nil }
        if !selectedTargets.isEmpty { pruneSelection() }
        if !isDirty { isDirty = true }
        scheduleAutosave()
        updatePlainScreen()
        rememberLastProjectConfig()
        if micModeChanged {
            syncMicrophoneRenders()
            // The microphone plays from a different finished render, if there is one.
            Task { await rebuildComposition(replacingItem: true) }
        }
        if faceTrackingChanged { updateFaceTracking() }
        if updated.processing != oldProcessing { updateSensitiveDataScan() }
        updateCameraMatte()
        if updated.cursor.followRecordedPositionOnHover != oldFollowsHovers || (updated.animation.mouseSpring == nil) != oldSpringIsNil { updateHoverDetection() }
        if silenceChanged { updateSilence() }
        if canvasChanged || slicesChanged || backgroundChanged || clicksChanged || cameraDelayChanged {
            Task { await rebuildComposition(replacingItem: slicesChanged || backgroundChanged || clicksChanged || cameraDelayChanged) }
        } else {
            // A new microphone mode already rebuilds the composition, mix and waveforms included.
            if audioChanged && !micModeChanged {
                waveforms.update(project: project, bundle: bundleURL, video: videoURL)
                audioMixTask?.cancel()
                audioMixTask = Task { await refreshAudioMix() }
            }
            if !onlyAudioChanged { scheduleRefresh() }
        }
    }

    // MARK: Rendering

    /// Refresh rate of the fastest display (60, or 120 with ProMotion).
    static var displayFrameRate: Int {
        max(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60, 30)
    }

    /// The tallest the preview is shown, in points: the preview size setting (480p … 2160p
    /// are heights in points, drawn at the backing scale).
    static var previewMaxHeight: CGFloat {
        CGFloat(Preferences.shared.playbackPreviewMaxHeight)
    }

    /// The preview's size in points: the stage fitted inside `available`, no taller than
    /// `maxHeight` points. Before the preview reports its space, the main screen's.
    static func previewDisplaySize(canvas: Size2, available: CGSize?, maxHeight: CGFloat) -> CGSize {
        let space = available ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: canvas.width, height: canvas.height)
        let height = min(space.height, maxHeight)
        guard space.width > 0, height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(space.width / canvas.width, height / canvas.height)
        return CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    /// Pixels the preview is drawn at: its displayed width × the backing scale × the preview
    /// quality, the stage scaled uniformly from that width.
    static func previewOutputSize(canvas: Size2, display: CGSize, backingScale: CGFloat, resolution: Double) -> Size2 {
        let k = display.width / max(canvas.width, 1) * backingScale * resolution
        return Size2(width: max((canvas.width * k).rounded(), 2), height: max((canvas.height * k).rounded(), 2))
    }

    var previewDisplaySize: CGSize {
        Self.previewDisplaySize(canvas: project.canvasSize, available: previewAvailableSpace, maxHeight: Self.previewMaxHeight)
    }

    private var previewOutputSize: Size2 {
        Self.previewOutputSize(canvas: project.canvasSize, display: previewDisplaySize, backingScale: previewBackingScale, resolution: preferences.playbackPreviewResolution)
    }

    /// The preview moved to a space or screen of another size; it is drawn again at its new
    /// size once the current update is done.
    func updatePreviewSpace(_ available: CGSize, backingScale: CGFloat) {
        let before = previewOutputSize
        previewAvailableSpace = available
        previewBackingScale = backingScale
        guard previewOutputSize != before, !isPreviewResizeScheduled else { return }
        isPreviewResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPreviewResizeScheduled = false
            self.applyPreviewOutputSize()
        }
    }

    private var isPreviewResizeScheduled = false

    /// The current composition drawn at `previewOutputSize`.
    private func applyPreviewOutputSize() {
        guard var configuration = baseConfiguration, let item = player.currentItem else { return }
        let output = previewOutputSize
        let size = CGSize(width: output.width, height: output.height)
        guard configuration.renderSize != size else { return }
        configuration.renderSize = size
        baseConfiguration = configuration
        item.videoComposition = AVVideoComposition(configuration: configuration)
        prewarmRenderer()
        scrubPreview?.close()
        scrubPreview = nil
        if isScrubbing { makeScrubPreview(); scrubPreview?.show(playbackMs: scrubTimeMs) }
        else if !isPlaying { seek(to: currentTimeMs, moveHead: false) }
    }

    /// New composition (canvas or preview size changed); keeps the playhead. With
    /// `replacingItem` the player gets a new item, needed when clips change the timing.
    func rebuildComposition(replacingItem: Bool = false) async {
        // New files (a finished microphone render) can change the mix.
        audioPlayer.projectDidChange()
        // The new composition carries the current mix.
        audioMixTask?.cancel()
        compositionGeneration += 1
        let generation = compositionGeneration
        itemReplacementPending = itemReplacementPending || replacingItem
        snapshotRequests += 1
        let request = snapshotRequests
        let project = self.project, cursors = self.cursors, bundle = bundleURL, output = previewOutputSize
        let snapshot = await Task.detached(priority: .userInitiated) {
            RenderState.makeSnapshot(project: project, cursors: cursors, assetsDirectory: bundle, outputSize: output)
        }.value
        // A newer rebuild supersedes this one.
        guard generation == compositionGeneration else { return }
        installSnapshot(snapshot, request: request)
        // New timing, camera delay or preview size: scrubbers start over.
        scrubPreview?.close()
        scrubPreview = nil
        if isScrubbing { makeScrubPreview(); scrubPreview?.show(playbackMs: scrubTimeMs) }
        waveforms.update(project: project, bundle: bundleURL, video: videoURL)
        do {
            let media = try await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundleURL))
            let asset = media.asset
            let output = previewOutputSize
            // Frames at the display's refresh rate: screen recordings have a variable, lower frame rate,
            // which made zooms and the cursor judder.
            let configuration = try await CompositionFactory.configuration(asset: asset, state: renderState, canvas: project.canvasSize, outputSize: output, fps: Self.displayFrameRate)
            guard generation == compositionGeneration else { return }
            let composition = AVVideoComposition(configuration: configuration)
            baseConfiguration = configuration
            prewarmRenderer()
            let replacesItem = itemReplacementPending
            itemReplacementPending = false
            if let item = player.currentItem, !replacesItem {
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
            guard generation == compositionGeneration else { return }
            errorMessage = "Could not load the recording: \(error.localizedDescription)"
        }
    }

    /// Rebuilds asked for so far; only the latest one installs its composition.
    private var compositionGeneration = 0
    /// A superseded rebuild that needed a new player item passes that need on.
    private var itemReplacementPending = false
    /// Render snapshots asked for so far, and the latest one shown: one made for an older
    /// request never replaces a newer one, whichever finishes first.
    private var snapshotRequests = 0
    private var installedSnapshotRequest = 0

    @discardableResult
    private func installSnapshot(_ snapshot: RenderState.Snapshot, request: Int) -> Bool {
        guard request > installedSnapshotRequest else { return false }
        installedSnapshotRequest = request
        renderState.replace(with: snapshot)
        return true
    }

    /// Volumes and mutes only change the mix of the current item.
    private func refreshAudioMix() async {
        guard let media = try? await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundleURL)),
              !Task.isCancelled else { return }
        player.currentItem?.audioMix = media.audioMix
    }

    /// The latest mix refresh; a newer volume change cancels it.
    private var audioMixTask: Task<Void, Never>?

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

    /// A context menu option under the pointer (`highlight` → `preview()`); not part of history,
    /// cleared when the pointer leaves it or the menu closes.
    var menuPreview: ((inout Project) -> Void)? {
        didSet { if oldValue != nil || menuPreview != nil { scheduleRefresh() } }
    }

    /// The project as rendered (with the hovered preset or menu option, if any).
    private var renderedProject: Project {
        guard presetPreview != nil || menuPreview != nil else { return project }
        var preview = project
        if let presetPreview { preview.apply(presetPreview) }
        menuPreview?(&preview)
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

    /// Redraws with files beside the project that changed (transcript, face data).
    func refreshRendering() { scheduleRefresh() }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let project = self.renderedProject
        let cursors = self.cursors
        let bundle = bundleURL
        let output = previewOutputSize
        snapshotRequests += 1
        let request = snapshotRequests
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                RenderState.makeSnapshot(project: project, cursors: cursors, assetsDirectory: bundle, outputSize: output)
            }.value
            guard !Task.isCancelled, let self, self.installSnapshot(snapshot, request: request) else { return }
            self.prewarmRenderer()
            // Re-assigning the composition drops cached frames.
            if let base = self.baseConfiguration, let item = self.player.currentItem {
                item.videoComposition = AVVideoComposition(configuration: base)
                if !self.isPlaying {
                    if self.isScrubbing { self.scrubPreview?.refresh() } else { self.seek(to: self.currentTimeMs, moveHead: false) }
                }
            }
        }
    }

    private var faceTrackingTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?

    /// "Hide during silence": finds the microphone's silences for the current minimum duration
    /// (`project.silenceChunks`), after the slider settles.
    private func updateSilence() {
        silenceTask?.cancel()
        guard project.camera.hideDuringSilenceMs != nil else { return }
        let project = self.project, bundle = bundleURL, recording = videoURL
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            try? await SilenceAnalyzer.ensure(project: project, bundle: bundle, recording: recording)
            guard !Task.isCancelled else { return }
            self?.scheduleRefresh()
        }
    }

    /// Turning face tracking on starts the webcam analysis (`project.cameraFaces`); partial
    /// results are saved and used as they come, so tracking works while it runs.
    private func updateFaceTracking() {
        faceTrackingTask?.cancel()
        faceTrackingTask = nil
        guard project.camera.enableFaceTracking, let name = project.recording.cameraFileName else { return }
        let bundle = bundleURL
        let movie = videoURL.deletingLastPathComponent().appendingPathComponent(name)
        let existing = CameraFaces.load(bundle: bundle)
        guard existing?.isComplete != true, FileManager.default.fileExists(atPath: movie.path) else { return }
        faceTrackingTask = Task.detached(priority: .utility) { [weak self] in
            let faces = try? await CameraFaceDetector.detect(movie: movie, previous: existing) { partial in
                try? partial.save(bundle: bundle)
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            if let faces { try? faces.save(bundle: bundle) }
            await MainActor.run { [weak self] in self?.scheduleRefresh() }
        }
    }

    private var sensitiveDataTask: Task<Void, Never>?
    private var sensitiveDataKey: String?

    /// Hide sensitive data / Hide faces: scans while either is on, again when the phrases or the
    /// face search change. Turning "Hide sensitive data" on or off alone does not start a scan
    /// (text is always found and filtered when drawn).
    func updateSensitiveDataScan() {
        let processing = project.processing
        guard processing.isAutoMasking else {
            sensitiveDataTask?.cancel()
            sensitiveDataTask = nil
            tasks.finish("sensitive-data")
            sensitiveDataKey = nil
            return
        }
        let key = processing.sensitiveDataCustomPhrases.joined(separator: ",") + "-" + (processing.autoMaskFaces ? "faces" : "")
        guard key != sensitiveDataKey else { return }
        sensitiveDataTask?.cancel()
        sensitiveDataKey = key
        let bundle = bundleURL, video = videoURL, durationMs = project.recording.durationMs
        let stored = SensitiveDataScan.load(bundle: bundle)
        if let stored, stored.isComplete, stored.matches(processing) {
            lastSensitiveDataResult = stored.detections
            scheduleRefresh()
            return
        }
        // Until the new scan has results, the last one finished in this session stays shown.
        let previous = lastSensitiveDataResult ?? []
        let phrases = processing.sensitiveDataCustomPhrases, faces = processing.autoMaskFaces
        try? SensitiveDataScan(customPhrases: phrases, detectFaces: faces, detections: [], finalUpToMs: 0, isComplete: false,
                               previousDetections: previous).save(bundle: bundle)
        scheduleRefresh()
        // "Detecting sensitive data", shown after 500 ms.
        tasks.finish("sensitive-data")
        tasks.register("sensitive-data", name: "Detecting sensitive data", showAfterMs: 500, progress01: 0)
        sensitiveDataTask = Task.detached(priority: .utility) { [weak self] in
            defer { Task { @MainActor [weak self] in self?.tasks.finish("sensitive-data") } }
            let detections = try? await SensitiveDataScans.scan(video: video, phrases: phrases, detectFaces: faces, bundle: bundle, onPartialResult: { partial in
                // Partial results show as they come (`project.sensitiveDataPartial`), with those
                // scanned ahead and the last finished result.
                try? SensitiveDataScan(customPhrases: phrases, detectFaces: faces, detections: partial.detections, finalUpToMs: partial.finalUpToMs,
                                       isComplete: false, provisionalDetections: partial.provisionalDetections,
                                       previousDetections: previous).save(bundle: bundle)
                let finalUpTo = partial.finalUpToMs
                Task { @MainActor [weak self] in
                    self?.tasks.update("sensitive-data", progress01: durationMs > 0 ? finalUpTo / durationMs : nil)
                    self?.scheduleRefresh()
                }
            })
            guard let detections, !Task.isCancelled else { return }
            try? SensitiveDataScan(customPhrases: phrases, detectFaces: faces, detections: detections, finalUpToMs: durationMs, isComplete: true).save(bundle: bundle)
            await MainActor.run { [weak self] in
                self?.lastSensitiveDataResult = detections
                self?.scheduleRefresh()
            }
        }
    }

    private var cameraMatteTask: Task<Void, Never>?
    private var cameraMatteURL: URL?
    /// The webcam's mattes, held while a cutout layout is used: frames come from memory or the
    /// project's cache while a sweep fills it in the background.
    private var cameraMatting: CameraMatting?

    /// A cutout layout matting the webcam opens its mattes ("Preparing camera cutout", shown
    /// after a second, while the person window is found and the model loads); dropping it stops
    /// the sweep.
    private func updateCameraMatte() {
        let movie = project.recording.cameraFileName.map { bundleURL.appendingPathComponent($0) }
        let wanted = project.isCutoutLayoutUsed ? movie : nil
        guard wanted != cameraMatteURL else { return }
        cameraMatteURL = wanted
        cameraMatteTask?.cancel()
        cameraMatteTask = nil
        let taskID = "camera-matte-" + bundleURL.path + "-0-opening"
        tasks.finish(taskID)
        cameraMatting = nil
        guard let wanted, FileManager.default.fileExists(atPath: wanted.path) else { return }
        tasks.register(taskID, name: "Preparing camera cutout", showAfterMs: 1000)
        cameraMatteTask = Task.detached(priority: .utility) { [weak self] in
            let matting = try? CameraMatting.open(videoURL: wanted, waitsForStoredMattes: false)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tasks.finish(taskID)
                guard !Task.isCancelled, self.cameraMatteURL == wanted else { return }
                self.cameraMatting = matting
            }
        }
    }

    /// The last finished scan's detections in this session, shown while a new scan runs.
    private var lastSensitiveDataResult: [SensitiveDataDetection]?

    private var hoverDetectionTask: Task<Void, Never>?

    /// The cursor follows hovers once the recording's hover changes are found
    /// (`project.cursorHoverChanges`); runs in the background and redraws when done.
    private func updateHoverDetection() {
        let project = self.project
        guard project.cursor.followRecordedPositionOnHover, project.animation.mouseSpring != nil, hoverDetectionTask == nil,
              CursorHovers.load(bundle: bundleURL)?.covers(durationMs: project.recording.durationMs) != true else { return }
        let bundle = bundleURL, video = videoURL
        hoverDetectionTask = Task.detached(priority: .utility) { [weak self] in
            if let times = try? await CursorHoverDetector.detect(video: video, events: project.mouseEvents, pointPixelScale: project.recording.pointPixelScale) {
                try? CursorHovers(chunks: [.init(startMs: 0, endMs: project.recording.durationMs, result: times)]).save(bundle: bundle)
            }
            await MainActor.run { [weak self] in
                self?.hoverDetectionTask = nil
                self?.scheduleRefresh()
            }
        }
    }

    private var prewarmTask: Task<Void, Never>?

    /// Compiles the moving-frame programs in the background so playback does not stall on them.
    private func prewarmRenderer() {
        prewarmTask?.cancel()
        let state = renderState, output = previewOutputSize, cameraSize = project.recording.cameraSize
        prewarmTask = Task.detached(priority: .utility) {
            CompositionFactory.prewarm(state: state, outputSize: output, cameraSize: cameraSize)
        }
    }

    /// `isStageFocusedOnPlainScreen`: paused with an add tool armed, or with the open mask
    /// under the playhead.
    var isStageFocusedOnPlainScreen: Bool {
        guard !isPlaying else { return false }
        if isAddZoomToolArmed || isAddMaskToolArmed || isAddLayoutToolArmed { return true }
        guard let id = openMaskID, let mask = project.masks.first(where: { $0.id == id }) else { return false }
        let t = currentSourceTimeMs
        return mask.startMs <= t && mask.endMs >= t
    }

    /// Switches the preview to or from the plain stage. The paused frame is drawn again unless
    /// a seek is about to draw it (`redraw: false`).
    private func updatePlainScreen(redraw: Bool = true) {
        let plain = isStageFocusedOnPlainScreen
        guard plain != renderState.isPlainScreen else { return }
        renderState.isPlainScreen = plain
        guard let base = baseConfiguration, let item = player.currentItem else { return }
        // Re-assigning the composition drops cached frames.
        item.videoComposition = AVVideoComposition(configuration: base)
        guard redraw, !isPlaying else { return }
        if isScrubbing { scrubPreview?.refresh() } else { seek(to: currentTimeMs, moveHead: false) }
    }

    /// Lighter motion blur while playing, full quality whenever not playing, hover scrubbing
    /// included. A frame left on screen after playback is drawn again at full quality.
    private func updateRenderQuality() {
        let quality: RenderQuality = isPlaying ? .playing : .pausedHigh
        let previous = renderState.quality
        guard quality != previous else { return }
        renderState.quality = quality
        if quality == .pausedHigh, previous == .playing,
           let base = baseConfiguration, let item = player.currentItem {
            item.videoComposition = AVVideoComposition(configuration: base)
            seek(to: currentTimeMs, moveHead: false)
        }
    }

    // MARK: Playback

    private var scrubTimeMs: Double = 0

    /// The source time the preview shows: the hovered moment while scrubbing, else the playhead.
    var previewSourceTimeMs: Double {
        isScrubbing ? resolver.playbackToSource(scrubTimeMs) : currentSourceTimeMs
    }

    func togglePlay() {
        isPlaying ? pause() : play(rate: effectiveRate)
    }

    func pause() {
        player.pause()
        stopManualPlayback()
        // Only changes are published: arrow-key steps pause first.
        if shuttleRate != nil { shuttleRate = nil }
        if isPlaying { isPlaying = false }
    }

    /// `playToward(dir)` for L (+1) and J (−1): the same direction doubles the speed up to
    /// 16×, the other one starts at the default speed.
    func playToward(_ direction: Double) {
        let same = isPlaying && (effectiveRate > 0) == (direction > 0)
        shuttleRate = same ? clamp(effectiveRate * 2, -16, 16) : direction * playbackRate
        play(rate: effectiveRate)
    }

    /// Plays at `rate`, wrapping from the end (or the start in reverse) first.
    private func play(rate: Double) {
        isScrubbing = false
        if rate > 0, currentTimeMs >= durationMs - 30 { seek(to: 0) }
        if rate < 0, currentTimeMs <= 30 { seek(to: durationMs) }
        let item = player.currentItem
        let native = rate > 0 && (rate <= 2 || item?.canPlayFastForward == true)
            || rate < 0 && (rate >= -1 ? item?.canPlayReverse == true : item?.canPlayFastReverse == true)
        if native {
            stopManualPlayback()
            player.rate = Float(rate)
        } else {
            player.pause()
            startManualPlayback(rate: rate)
        }
        isPlaying = true
    }

    /// "Show editor sidebar" / "Show editor timeline".
    func toggleSidebarShown() {
        switch layoutType {
        case .edit: layoutType = .hideSidebar
        case .hideTimeline: layoutType = .preview
        case .hideSidebar: layoutType = .edit
        case .preview: layoutType = .hideTimeline
        }
    }

    func toggleTimelineShown() {
        switch layoutType {
        case .edit: layoutType = .hideTimeline
        case .hideSidebar: layoutType = .preview
        case .hideTimeline: layoutType = .edit
        case .preview: layoutType = .hideSidebar
        }
    }

    /// `playbackLoop`, or the cursor's "Loop cursor position".
    var shouldLoop: Bool { forcesLoop || preferences.playbackLoop || project.cursor.loopPositionBeforeEndMs != nil }
    /// The quick export widget's preview always loops (`loop: true`).
    var forcesLoop = false

    /// At the end: loop back and keep the speed, else stop.
    private func reachedEnd() {
        let rate = manualTimer != nil ? manualRate : effectiveRate
        guard shouldLoop else {
            pause()
            return
        }
        seek(to: rate > 0 ? 0 : durationMs)
        play(rate: rate)
    }

    private func startManualPlayback(rate: Double) {
        stopManualPlayback()
        manualRate = rate
        manualLast = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.manualTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualTimer = timer
    }

    private func stopManualPlayback() {
        manualTimer?.invalidate()
        manualTimer = nil
    }

    private func manualTick() {
        let now = CACurrentMediaTime()
        let deltaMs = (now - manualLast) * 1000 * manualRate
        var next = currentTimeMs + deltaMs
        // The playhead follows the audio being heard.
        if let heard = audioPlayer.audibleTimeMs { next += PlaybackClockChase.correction(errorMs: heard - next, deltaMs: deltaMs) }
        manualLast = now
        if next < 0 || next > durationMs {
            currentTimeMs = clamp(next, 0, durationMs)
            reachedEnd()
            return
        }
        currentTimeMs = next
        chaseSeek(to: CMTime(seconds: next / 1000, preferredTimescale: 600))
        followPlayhead()
    }

    /// Moves the playhead (click on the timeline, buttons, shortcuts). Times round to 60 fps.
    func seek(to timeMs: Double, moveHead: Bool = true) {
        let frame = 1000.0 / 60
        let clamped = clamp((timeMs / frame).rounded() * frame, 0, durationMs)
        if moveHead {
            currentTimeMs = clamped
            updatePlainScreen(redraw: false)
            if isPlaying { audioPlayer.timeDidSet() } else { audioPlayer.displayedTimeDidChange(clamped) }
        }
        chaseSeek(to: CMTime(seconds: clamped / 1000, preferredTimescale: 600))
    }

    private var seekInFlight = false
    private var pendingSeek: CMTime?

    /// One exact seek at a time; while it runs only the latest target waits, so fast hover
    /// scrubbing never queues up stale frames.
    private func chaseSeek(to time: CMTime) {
        guard !seekInFlight else {
            pendingSeek = time
            return
        }
        seekInFlight = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.chaseSeek(to: next)
                }
            }
        }
    }

    /// Hover scrubbing while paused (the head stays where it is).
    func scrub(to timeMs: Double) {
        guard !isPlaying else { return }
        isScrubbing = true
        scrubTimeMs = clamp(timeMs, 0, durationMs)
        audioPlayer.displayedTimeDidChange(scrubTimeMs)
        if scrubPreview == nil { makeScrubPreview() }
        scrubDisplay.activate()
        scrubPreview?.show(playbackMs: scrubTimeMs)
    }

    private func makeScrubPreview() {
        let camera = project.recording.cameraFileName
            .map { videoURL.deletingLastPathComponent().appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let preview = ScrubPreview(
            state: renderState, screenURL: videoURL, cameraURL: camera, cameraOffsetMs: project.camera.delayAdjustmentMs,
            resolver: project.resolver, output: previewOutputSize
        )
        let display = scrubDisplay
        preview.onImage = { buffer in display.show(buffer) }
        scrubPreview = preview
    }

    /// The player never left the playhead, so hiding the scrub frames is enough.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        audioPlayer.displayedTimeDidChange(currentTimeMs)
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
        if isPlaying && shuttleRate == nil { play(rate: rate) }
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

    /// `keepPlayheadVisible`: a playhead leaving the view pages it to the left edge (the right
    /// edge in reverse), unless the user scrolled during this playback.
    private func followPlayhead() {
        guard !followSuspended else { return }
        if currentTimeMs > scrollOffsetMs + visibleDurationMs {
            scrollOffsetMs = currentTimeMs
            clampScroll()
        } else if currentTimeMs < scrollOffsetMs {
            scrollOffsetMs = currentTimeMs - visibleDurationMs
            clampScroll()
        }
    }

    // MARK: Sidebar

    func openSidebar(_ root: SidebarRoot) {
        sidebarItem = nil
        sidebarRoot = root
        // Opening the shortcuts panel focuses its track.
        if root == .shortcuts { focusedTrack = "shortcuts" }
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

    /// `setSidebarItem`: opening an item disarms the add tool.
    func setSidebarItem(_ item: SidebarItem) {
        isAddZoomToolArmed = false
        isAddMaskToolArmed = false
        isAddLayoutToolArmed = false
        sidebarItem = item
    }

    func openZoom(_ id: UUID) {
        setSidebarItem(.zoom(id))
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
        setSidebarItem(.slice(id))
    }

    var openMaskID: UUID? {
        if case .mask(let id) = sidebarItem { return id }
        return nil
    }

    func openMask(_ id: UUID) {
        setSidebarItem(.mask(id))
        focusedTrack = "masks"
    }

    /// The paused preview's click targets right now (canvas pixels), from one evaluation of the
    /// current frame.
    struct PreviewTargets {
        var recording: Rect2
        var recordingCornerRadius: Double
        var camera: (rect: Rect2, cornerRadius: Double)?
        var loupe: Rect2?
        var shortcuts: Rect2?
        var shortcutsCornerRadius: Double
        var cursor: Rect2?
    }

    var previewTargets: PreviewTargets {
        let snapshot = renderState.current
        let frame = renderState.isPlainScreen ? snapshot.track.plainFrame(at: currentTimeMs) : snapshot.track.frame(at: currentTimeMs)
        return PreviewTargets(
            recording: frame.screenRect,
            recordingCornerRadius: recordingAreaCornerRadius(snapshot, frame),
            camera: cameraArea(frame),
            loupe: loupeArea(frame),
            shortcuts: shortcutsArea(snapshot),
            shortcutsCornerRadius: shortcutsCornerRadius(snapshot),
            cursor: cursorArea(snapshot, frame)
        )
    }

    /// Where the cursor image is drawn right now (canvas pixels), if visible.
    private func cursorArea(_ snapshot: RenderState.Snapshot, _ frame: CameraFrame) -> Rect2? {
        guard !project.cursor.hide, frame.cursorOpacity > 0.01, let position = frame.cursor else { return nil }
        let layout = snapshot.track.layout
        let asset = cursors.asset(named: frame.cursorName)
        let videoToCanvas = frame.screenRect.width / max(layout.videoSize.width, 1)
        let tip = layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect)
        return asset.rect(tip: tip, visibleHeight: project.cursor.size * videoToCanvas * frame.cursorScale)
    }

    private func recordingAreaCornerRadius(_ snapshot: RenderState.Snapshot, _ frame: CameraFrame) -> Double {
        let area = frame.screenRect
        let zoom = area.width / max(snapshot.track.layout.restScreen.width, 1)
        return min(project.style.cornerRadius * zoom, min(area.width, area.height) / 2)
    }

    /// Where the recording is drawn on the canvas right now (canvas pixels), for overlays. The
    /// current press's keys in canvas units, for the paused preview's click target.
    private func shortcutsArea(_ snapshot: RenderState.Snapshot) -> Rect2? {
        guard project.captions.enableShortcuts else { return nil }
        let canvas = snapshot.track.layout.canvas
        let captionsShown = project.captions.enableTranscript && hasVisibleCaptionWords
        return ShortcutTrack(project: project, canvas: canvas, captionsShown: captionsShown)?.currentRect(atPlayback: currentTimeMs)
    }

    /// The keys' corner radius in canvas units (`ratio × 128` stage units).
    private func shortcutsCornerRadius(_ snapshot: RenderState.Snapshot) -> Double {
        project.captions.shortcutsSizeRatio * 128 * snapshot.track.layout.canvas.height / 1080
    }

    /// Whether any caption word shows, kept until the transcript, clips or sound labels change.
    private var hasVisibleCaptionWords: Bool {
        let key = CaptionWordsKey(resolver: resolver, showSoundLabels: project.captions.showSoundLabels)
        if let cached = visibleCaptionWordsCache, cached.key == key { return cached.value }
        let value = !CaptionWords.visible(clientTranscript, resolver: resolver, showSoundLabels: key.showSoundLabels).isEmpty
        visibleCaptionWordsCache = (key, value)
        return value
    }

    /// The lens circle in canvas units while it is mostly there (`LOUPE` marker).
    private func loupeArea(_ frame: CameraFrame) -> Rect2? {
        guard let lens = frame.loupe, lens.radius > 0, lens.presence >= 0.5 else { return nil }
        let s = project.videoRect(inScreen: frame.screenRect)
        let r = lens.radius * s.width
        return Rect2(x: s.x + lens.center.x * s.width - r, y: s.y + lens.center.y * s.height - r, width: 2 * r, height: 2 * r)
    }

    /// Opens the enabled loupe at the playhead, its lead-in included.
    func openLoupeAtPlayhead() {
        let t = currentSourceTimeMs
        let lead = project.animation.leadInMs
        guard let zoom = project.zooms.first(where: { !$0.isDisabled && $0.presentation == .loupe && t >= $0.startMs - lead && t <= $0.endMs }) else { return }
        openZoom(zoom.id)
        showToast("Opened zoom settings", durationMs: 1000)
    }

    /// The webcam on the canvas while it is shown (canvas pixels).
    private func cameraArea(_ frame: CameraFrame) -> (rect: Rect2, cornerRadius: Double)? {
        guard !project.camera.hide, let rect = frame.cameraRect, frame.cameraOpacity > 0.5, rect.width > 1, rect.height > 1 else { return nil }
        return (rect, min(frame.cameraCornerRadius, min(rect.width, rect.height) / 2))
    }

    var recordingAreaRect: Rect2 {
        renderState.frame(at: currentTimeMs).screenRect
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
            showToast("Not enough space in selected timeline position to add a new mask")
            return
        }
        var mask = MaskRange(startMs: start, endMs: end, bounds: bounds.map { [$0] } ?? project.defaultMaskBounds, type: type)
        // The last edited mask style, under the explicit inputs.
        if let style = LastEditedMaskStyle.stored {
            mask.blur = style.blur
            mask.highlightMaskOpacity = style.highlightMaskOpacity
        }
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

    func updateMask(_ id: UUID, _ body: (inout MaskRange) -> Void) {
        let before = project.masks.first(where: { $0.id == id })
        change { project in
            guard let index = project.masks.firstIndex(where: { $0.id == id }) else { return }
            body(&project.masks[index])
        }
        if let before, let mask = project.masks.first(where: { $0.id == id }) { LastEditedMaskStyle.capture(mask, ifChangedFrom: before) }
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
        updateMask(id) {
            $0.startMs = newStart
            $0.endMs = newStart + mask.durationMs
        }
    }

    func resizeMask(_ id: UUID, leading: Bool, to time: Double) {
        guard let mask = project.masks.first(where: { $0.id == id }) else { return }
        let others = project.sortedMasks.filter { $0.id != id }
        let minimum = MaskRange.minimumDurationMs
        updateMask(id) {
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
            showToast("The part you want to cut is too short", durationMs: 2000)
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
        let before = project.masks
        change { project in
            for index in project.masks.indices { project.masks[index].highlightMaskOpacity = opacity }
        }
        for (old, new) in zip(before, project.masks) { LastEditedMaskStyle.capture(new, ifChangedFrom: old) }
        showToast("Highlight mask opacity applied to all masks")
    }

    /// Split-tool click: the length check uses the pointer's time, the cut the beam's, which snaps
    /// to the playhead within 100 ms. Nil after the "too short" toast.
    func beamSplitSource(startMs: Double, endMs: Double, minimumMs: Double, hoverPlaybackMs: Double) -> Double? {
        let resolver = project.resolver
        let source = resolver.playbackToSource(hoverPlaybackMs)
        guard min(abs(startMs - source), abs(endMs - source)) >= minimumMs else {
            showToast("Can't cut item shorter than \(String(format: "%.1f", minimumMs / 1000))s", durationMs: 1000)
            return nil
        }
        return resolver.playbackToSource(beamPlaybackMs(hoverPlaybackMs))
    }

    /// Where the split beam is drawn: the playhead when the pointer is within 100 ms of it.
    func beamPlaybackMs(_ hoverPlaybackMs: Double) -> Double {
        abs(hoverPlaybackMs - currentTimeMs) < 100 ? currentTimeMs : hoverPlaybackMs
    }

    /// Recording time at the playhead.
    var currentSourceTimeMs: Double { resolver.playbackToSource(currentTimeMs) }

    // MARK: Clips

    /// Splits the clip at a playback time; "The part you want to cut is too short" otherwise.
    func splitSlice(atPlayback playbackMs: Double) {
        let source = project.resolver.playbackToSource(playbackMs)
        guard project.canSplitSlice(at: source) else {
            showToast("The part you want to cut is too short", durationMs: 2000)
            return
        }
        change { $0.splitSlice(at: source) }
    }

    /// Trim by dragging an edge (playback time), moving the playhead to the trimmed edge.
    func trimSlice(_ id: UUID, edge: Project.SliceEdge, toSource sourceMs: Double) {
        change { project in
            switch edge {
            case .start: project.updateSlice(id, sourceStartMs: sourceMs)
            case .end: project.updateSlice(id, sourceEndMs: sourceMs)
            }
        }
        guard let slice = project.slices.first(where: { $0.id == id }) else { return }
        seek(to: project.resolver.sourceToPlayback(edge == .start ? slice.sourceStartMs : slice.sourceEndMs))
    }

    func updateSlice(_ id: UUID, _ body: (inout Slice) -> Void) {
        change { project in
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

    /// Removes a clip and the items it left entirely cut out; the playhead stays on the same
    /// recording frame (`stickyAction`).
    func removeSlice(_ id: UUID) {
        stickyPlayhead {
            change {
                $0.removeSlice(id)
                $0.removeNonPresentTimelineItems()
            }
        }
    }

    /// X "Remove slice till previous cut": the clip before the one under the playhead. False
    /// when there is none.
    @discardableResult
    func rippleRemoveSlice() -> Bool {
        guard project.slices.count > 1, let index = project.sliceIndex(atSource: currentSourceTimeMs), index > 0 else { return false }
        removeSlice(project.slices[index - 1].id)
        return true
    }

    /// `playback.stickyAction()`: keeps the playhead on its recording moment across a
    /// change of the timing.
    func stickyPlayhead(_ body: () -> Void) {
        let source = project.resolver.playbackToSource(currentTimeMs) + 0.0001
        body()
        seek(to: project.resolver.sourceToPlayback(source))
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
    func addZoom(startMs: Double, durationMs requested: Double = ZoomRange.initialDurationMs, manualTarget: Vec2? = nil, presentation: ZoomPresentation = .screen) -> UUID? {
        guard let gap = freeRange(around: startMs + 1) else { return nil }
        let start = clamp(startMs, gap.start, gap.end)
        let end = min(start + requested, gap.end)
        guard end - start >= ZoomRange.minimumDurationMs else { return nil }
        let zoom = ZoomRange(
            startMs: start,
            endMs: end,
            scale: preferences.defaultZoomLevel ?? 2,
            mode: manualTarget == nil ? .auto : .manual,
            manualTarget: manualTarget ?? .center01,
            presentation: presentation
        )
        change { $0.zooms.append(zoom) }
        UserDefaults.standard.set(true, forKey: "onboarding.creating-zoom")
        openZoom(zoom.id)
        return zoom.id
    }

    func updateZoom(_ id: UUID, _ body: (inout ZoomRange) -> Void) {
        let before = project.zooms.first(where: { $0.id == id })
        change { project in
            guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            body(&project.zooms[index])
            project.zooms[index].isGenerated = false
        }
        if let before, let zoom = project.zooms.first(where: { $0.id == id }) { LastEditedZoomStyle.capture(zoom, ifChangedFrom: before) }
    }

    /// `addZoomAtPlayhead`: the add tool and its "Automatic zoom" button. The last edited zoom
    /// style applies first, then the explicit inputs. Inside a zoom, that zoom is split at the
    /// playhead and the inputs go to the right part.
    func addZoomAtPlayhead(presentation: ZoomPresentation, manualTarget: Vec2? = nil) {
        let t = currentSourceTimeMs
        let style = LastEditedZoomStyle.stored
        func applyInputs(_ zoom: inout ZoomRange) {
            if let style {
                zoom.scale = style.zoom
                zoom.loupeOptions = style.loupeOptions
                zoom.isInstant = style.hasInstantAnimation
            }
            zoom.presentation = presentation
            if let manualTarget {
                zoom.mode = .manual
                zoom.manualTarget = manualTarget
            }
        }
        if let inside = project.zooms.first(where: { t > $0.startMs && t < $0.endMs }) {
            splitZoom(inside.id, at: t)
            if let right = project.zooms.first(where: { $0.id != inside.id && abs($0.startMs - t) < 0.5 }) {
                change { project in
                    guard let i = project.zooms.firstIndex(where: { $0.id == right.id }) else { return }
                    applyInputs(&project.zooms[i])
                }
                openZoom(right.id)
                return
            }
        }
        guard let id = addZoom(startMs: t, manualTarget: manualTarget, presentation: presentation) else {
            showToast("Could not insert zoom at currently selected time")
            return
        }
        change { project in
            guard let i = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            applyInputs(&project.zooms[i])
        }
    }

    /// Drag-move, clamped to the neighbours and the timeline bounds.
    func moveZoom(_ id: UUID, toStart start: Double) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let others = sortedZooms.filter { $0.id != id }
        let lower = others.last(where: { $0.endMs <= zoom.startMs + 0.5 })?.endMs ?? 0
        let upper = others.first(where: { $0.startMs >= zoom.endMs - 0.5 })?.startMs ?? project.recording.durationMs
        let newStart = clamp(start, lower, upper - zoom.durationMs)
        updateZoom(id) {
            $0.startMs = newStart
            $0.endMs = newStart + zoom.durationMs
        }
    }

    func resizeZoom(_ id: UUID, leading: Bool, to time: Double) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let others = sortedZooms.filter { $0.id != id }
        let minimum = ZoomRange.minimumDurationMs
        updateZoom(id) {
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
    }

    /// Splits a zoom at `timeMs` (the playhead, or the split tool's beam).
    func splitZoom(_ id: UUID, at timeMs: Double) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let minimum = ZoomRange.minimumDurationMs
        guard timeMs - zoom.startMs >= minimum, zoom.endMs - timeMs >= minimum else {
            showToast("The part you want to cut is too short", durationMs: 2000)
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

    /// A recording opened right after it was made (`newRecording`), until it is saved.
    var isNewRecording = false

    func saveNow() {
        do {
            project.lastSavedAt = Date()
            try ProjectStore.save(project, to: bundleURL)
            isDirty = false
            writePreviewImage()
        } catch {
            showError(error)
        }
    }

    /// "Save" ⌘S.
    func saveFromMenu() {
        saveNow()
        showToast("Project saved", durationMs: 2000)
    }

    /// "Save as..." ⇧⌘S: copies the project there and keeps editing the copy.
    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save project as..."
        panel.message = "Pick location to save project"
        panel.nameFieldStringValue = "\(projectName).\(ProjectStore.fileExtension)"
        panel.directoryURL = bundleURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = ProjectStore.fileExtension
        guard url.pathExtension == ext else {
            Dialogs.info(title: "Invalid file name", message: "File extension must be .\(ext)")
            return
        }
        guard url.lastPathComponent != ".\(ext)", !url.deletingPathExtension().lastPathComponent.isEmpty else {
            Dialogs.info(title: "Invalid file name", message: "File name cannot be empty")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            try FileManager.default.copyItem(at: bundleURL, to: url)
            bundleURL = url
            saveNow()
            objectWillChange.send()
            AppController.shared.editorRenamed(self)
            showToast("Project saved", durationMs: 2000)
            Task { await rebuildComposition() }
        } catch {
            Dialogs.error("Could not save the project: \(error.localizedDescription)")
        }
    }

    /// "Close without saving".
    func discardChanges() { isDirty = false }

    /// "Delete and close": trashed without asking again.
    func trashProject() {
        pause()
        isDirty = false
        try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
    }

    /// The styled frame at the playhead, for the Recent Projects cards (`previewImagePath`).
    func writePreviewImage() {
        guard let item = player.currentItem else { return }
        let asset = item.asset, composition = item.videoComposition, time = player.currentTime(), bundle = bundleURL
        Task.detached { await ProjectPreview.write(asset: asset, videoComposition: composition, time: time, to: bundle) }
    }

    /// Renames the project folder. Forbidden characters are stripped.
    func rename(to rawName: String) {
        let forbidden = CharacterSet(charactersIn: "\\/*?\"<>|%¿:")
        let cleaned = rawName.components(separatedBy: forbidden).joined().trimmingCharacters(in: .whitespaces)
        if cleaned != rawName.trimmingCharacters(in: .whitespaces) {
            showToast("Filename contains forbidden characters", kind: .warning, durationMs: 2000)
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

    /// "Quick export to clipboard" ⌥⌘C / "Quick export to file..." ⌥⌘S, with the quick export settings.
    func quickExport(_ target: ExportTarget) {
        guard !exports.isExporting else { return }
        pause()
        exports.start(project: project, videoURL: videoURL, projectName: projectName, settings: preferences.widgetExportSettings.current, target: target)
    }

    /// "Export to file..." / "Export to clipboard" with the export picker's current settings.
    func exportWithCurrentSettings(_ target: ExportTarget) {
        guard !exports.isExporting else { return }
        pause()
        exports.start(project: project, videoURL: videoURL, projectName: projectName, settings: preferences.exportSettings.current, target: target)
    }

    /// "Extract raw recording files...": the recorded movies copied into a folder.
    func extractRawRecordingFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select folder to extract raw recording files"
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let names = [project.recording.videoFileName, project.recording.cameraFileName].compactMap { $0 }
        for name in names {
            let source = videoURL.deletingLastPathComponent().appendingPathComponent(name)
            var target = folder.appendingPathComponent(name)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\((name as NSString).deletingPathExtension) \(n).\((name as NSString).pathExtension)")
                n += 1
            }
            try? FileManager.default.copyItem(at: source, to: target)
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// "Copy and zip project": the project folder zipped and put on the clipboard.
    func copyAndZipProject() {
        let bundle = bundleURL, name = projectName
        if isDirty { saveNow() }
        Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent("\(name).zip")
            let ok = (try? await BlockingWork.run("project zip") { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, zip.path]
                return (try? process.run()) != nil && { process.waitUntilExit(); return process.terminationStatus == 0 }()
            }) ?? false
            await MainActor.run { [weak self] in
                if ok {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([zip as NSURL])
                    self?.showToast("Copied project to clipboard")
                } else {
                    self?.showToast("Failed to copy project to clipboard", kind: .error)
                }
            }
        }
    }

    /// "Export current frame as image...": the styled frame at 2160 px height as PNG,
    /// "<name> - Frame <n>", then shown in Finder.
    func exportCurrentFrame() {
        let frame = Int((currentTimeMs / 1000 * 60).rounded(.down))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(projectName) - Frame \(frame).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let image = await frameImage(height: 2160) else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The styled frame at the playhead, rendered at `height` px.
    private func frameImage(height: Double) async -> CGImage? {
        guard let asset = player.currentItem?.asset else { return nil }
        let canvas = project.canvasSize
        let output = Size2(width: (height * canvas.aspectRatio / 2).rounded() * 2, height: height)
        guard let configuration = try? await CompositionFactory.configuration(asset: asset, state: renderState, canvas: canvas, outputSize: output) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = AVVideoComposition(configuration: configuration)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: currentTimeMs / 1000, preferredTimescale: 600)).image
    }

    /// "Copy current frame as image", also at 2160 px.
    func copyCurrentFrame() {
        Task {
            guard let image = await frameImage(height: 2160) else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            showToast("Current frame image copied to clipboard")
        }
    }

    // MARK: Media keys

    private var mediaKeyTargets: [(MPRemoteCommand, Any)] = []

    /// The OS media controls drive the preview, titled "Regrava Studio Preview".
    /// The editor whose handlers are registered: only the front one gets the media keys.
    private static weak var mediaKeysOwner: EditorModel?

    func registerMediaKeys() {
        if let owner = Self.mediaKeysOwner, owner !== self { owner.unregisterMediaKeys() }
        Self.mediaKeysOwner = self
        unregisterMediaKeys()
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            mediaKeyTargets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in if self?.isPlaying == false { self?.togglePlay() } }
        on(center.pauseCommand) { [weak self] _ in self?.pause() }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay() }
        center.skipBackwardCommand.preferredIntervals = [1]
        center.skipForwardCommand.preferredIntervals = [1]
        on(center.skipBackwardCommand) { [weak self] _ in self?.step(milliseconds: -1000) }
        on(center.skipForwardCommand) { [weak self] _ in self?.step(milliseconds: 1000) }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime * 1000) }
        }
        on(center.previousTrackCommand) { [weak self] _ in self?.pause(); self?.seek(to: 0) }
        on(center.nextTrackCommand) { [weak self] _ in self.map { $0.pause(); $0.seek(to: $0.durationMs) } }
        on(center.stopCommand) { [weak self] _ in self?.pause(); self?.seek(to: 0) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Regrava Studio Preview", MPMediaItemPropertyArtist: "Regrava Studio"]
    }

    private func unregisterMediaKeys() {
        for (command, target) in mediaKeyTargets { command.removeTarget(target) }
        mediaKeyTargets = []
    }

    func tearDown() {
        unregisterMediaKeys()
        if Self.mediaKeysOwner === self {
            Self.mediaKeysOwner = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        scrubPreview?.close()
        scrubPreview = nil
        audioPlayer.close()
        // A pending transcript edit is written right away.
        if transcriptSaveTask != nil, let transcript {
            transcriptSaveTask?.cancel()
            try? transcript.save(bundle: bundleURL)
        }
        sensitiveDataTask?.cancel()
        setAnalysisDemand(nil)
        cameraMatteTask?.cancel()
        cameraMatting?.stop()
        cameraMatting = nil
        faceTrackingTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        // Reverse and fast playback run on a main run loop timer.
        stopManualPlayback()
        refreshTask?.cancel()
        prewarmTask?.cancel()
        audioMixTask?.cancel()
        autosaveTask?.cancel()
    }
}
