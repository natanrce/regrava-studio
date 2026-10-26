@preconcurrency import AVFoundation
import AppKit
import RegravaCapture
import RegravaCore

/// "Create project from video...": a video file becomes a new project. Its picture and first
/// sound are copied as they are (no re-encode), the sound kept as system audio, with no mouse or
/// key events; the project is named "Regrava-studio-<10 random characters>".
@MainActor
enum VideoImport {
    static func pickAndCreate() {
        let panel = NSOpenPanel()
        panel.message = "Select video file"
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let video = panel.url else { return }
        Task { await create(from: video) }
    }

    static func create(from video: URL) async {
        let message = "Creating project from video"
        LoaderWindow.shared.show("\(message) (0%)")
        defer { LoaderWindow.shared.hide() }
        do {
            let result = try await makeRecording(from: video) { progress in
                LoaderWindow.shared.show("\(message) (\(Int((progress * 100).rounded()))%)")
            }
            let made = try RecordingFolders.createProject(from: result.capture, folder: result.folder)
            AppController.shared.recording.closePicker()
            AppController.shared.openProject(bundle: made.bundle, project: made.project, isNewRecording: true)
        } catch {
            Dialogs.error(error.localizedDescription)
        }
    }

    private static func randomName() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "Regrava-studio-" + String((0..<10).map { _ in letters.randomElement()! })
    }

    /// The video and its first sound in a recording folder, as a finished recording.
    private static func makeRecording(from video: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (capture: CaptureResult, folder: URL) {
        let asset = AVURLAsset(url: video)
        guard let picture = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.failed("The selected file has no video.")
        }
        let duration = try await asset.load(.duration)
        let size = try await picture.load(.naturalSize).applying(try await picture.load(.preferredTransform))
        let sound = try await asset.loadTracks(withMediaType: .audio).first

        let folder = RecordingFolders.root.appendingPathComponent(randomName(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        if let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(range, of: picture, at: .zero)
            track.preferredTransform = try await picture.load(.preferredTransform)
        }
        if let sound, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, try await sound.load(.timeRange).duration)), of: sound, at: .zero)
        }
        let output = folder.appendingPathComponent(RecordingFinalizer.videoFileName)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.failed("The selected file can't be imported.")
        }
        let watcher = Task { @MainActor in
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: .mov)
        progress(1)
        let capture = CaptureResult(
            videoURL: output,
            mouseEvents: [],
            customCursors: [],
            keystrokes: [],
            audioSources: sound == nil ? [] : [.systemAudio],
            cameraURL: nil,
            cameraSize: nil,
            markersMs: [],
            videoSize: Size2(width: abs(size.width).rounded(), height: abs(size.height).rounded()),
            // The imported display's recording scale is 0.5.
            pointPixelScale: 2,
            durationMs: duration.seconds * 1000,
            fps: 60
        )
        return (capture, folder)
    }
}
