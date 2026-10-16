import AVFoundation
import AppKit
import Combine
import RegravaCore
import RegravaRender
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    let bundleURL: URL
    let player = AVPlayer()

    @Published var project: Project {
        didSet { if project != oldValue { scheduleRefresh() } }
    }
    @Published var selectedZoomID: UUID?
    @Published private(set) var currentTimeMs: Double = 0
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?

    private let cursor = CursorAsset.defaultArrow()
    private let renderState: RenderState
    private var baseComposition: AVMutableVideoComposition?
    private var timeObserver: Any?
    private var refreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(bundleURL: URL, project: Project) {
        self.bundleURL = bundleURL
        self.project = project
        renderState = RenderState(project: project, cursor: cursor)
    }

    var durationMs: Double { project.recording.durationMs }

    var selectedZoom: ZoomRange? {
        project.zooms.first { $0.id == selectedZoomID }
    }

    func prepare() async {
        let asset = AVURLAsset(url: ProjectStore.videoURL(bundle: bundleURL, project: project))
        do {
            let composition = try await CompositionFactory.make(asset: asset, state: renderState, canvas: project.canvasSize)
            baseComposition = composition
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentTimeMs = time.seconds * 1000
                    self.isPlaying = self.player.rate != 0
                }
            }
        } catch {
            errorMessage = "Could not load the recording: \(error.localizedDescription)"
        }
    }

    // MARK: Playback

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTimeMs >= durationMs - 50 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to timeMs: Double) {
        let clamped = clamp(timeMs, 0, durationMs)
        currentTimeMs = clamped
        player.seek(to: CMTime(seconds: clamped / 1000, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Zoom editing

    func updateZoom(_ id: UUID, _ change: (inout ZoomRange) -> Void) {
        guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = project.zooms[index]
        change(&zoom)
        zoom.startMs = clamp(zoom.startMs, 0, durationMs - ZoomRange.minimumDurationMs)
        zoom.endMs = clamp(zoom.endMs, zoom.startMs + ZoomRange.minimumDurationMs, durationMs)
        zoom.isGenerated = false
        project.zooms[index] = zoom
    }

    func addZoomAtPlayhead() {
        let start = clamp(currentTimeMs, 0, max(durationMs - 1000, 0))
        let zoom = ZoomRange(startMs: start, endMs: min(start + 3000, durationMs), scale: project.autoZoom.scale)
        project.zooms.append(zoom)
        project.zooms.sort { $0.startMs < $1.startMs }
        selectedZoomID = zoom.id
    }

    func deleteSelectedZoom() {
        guard let id = selectedZoomID else { return }
        project.zooms.removeAll { $0.id == id }
        selectedZoomID = nil
    }

    func regenerateAutomaticZooms() {
        project.autoZoom.isEnabled = true
        project.regenerateAutomaticZooms()
        selectedZoomID = nil
    }

    func removeAllZooms() {
        project.zooms.removeAll()
        selectedZoomID = nil
    }

    // MARK: Rendering refresh

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let project = self.project
        let cursor = self.cursor
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                RenderState.makeSnapshot(project: project, cursor: cursor)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.renderState.replace(with: snapshot)
            self.applyComposition()
        }
        scheduleSave()
    }

    /// Re-assigning the composition makes AVFoundation drop cached frames and re-render.
    private func applyComposition() {
        guard let base = baseComposition, let item = player.currentItem,
              let copy = base.mutableCopy() as? AVMutableVideoComposition else { return }
        copy.renderSize = CGSize(width: project.canvasSize.width.rounded(), height: project.canvasSize.height.rounded())
        item.videoComposition = copy
        if player.rate == 0 { seek(to: currentTimeMs) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try ProjectStore.save(project, to: bundleURL)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Export

    let exports = ExportController()

    var projectName: String { bundleURL.deletingPathExtension().lastPathComponent }
    var videoURL: URL { ProjectStore.videoURL(bundle: bundleURL, project: project) }

    /// `openExportPicker` (⌘⇧E): pauses playback and opens the picker.
    func openExportPicker() {
        guard !exports.isExporting else { return }
        player.pause()
        exports.openPicker()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}
