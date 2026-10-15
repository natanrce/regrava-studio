import AVFoundation
import CoreImage
import RegravaCore
import Foundation

/// Thread-safe holder for what the video composition renders. The editor swaps it when the
/// project changes; the AVFoundation filter handler reads it on its own threads.
public final class RenderState: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let track: CameraTrack
        public let compositor: FrameCompositor
    }

    private let lock = NSLock()
    private var snapshot: Snapshot

    public init(project: Project, cursor: CursorAsset? = CursorAsset.defaultArrow()) {
        snapshot = Self.makeSnapshot(project: project, cursor: cursor)
    }

    public static func makeSnapshot(project: Project, cursor: CursorAsset?) -> Snapshot {
        let track = CameraTrack(project: project)
        let compositor = FrameCompositor(project: project, layout: track.layout, cursor: cursor)
        return Snapshot(track: track, compositor: compositor)
    }

    public var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func replace(with newSnapshot: Snapshot) {
        lock.lock()
        snapshot = newSnapshot
        lock.unlock()
    }

    public func render(source: CIImage, timeMs: Double) -> CIImage {
        let s = current
        return s.compositor.compose(source: source, frame: s.track.frame(at: timeMs))
    }
}

public enum CompositionFactory {
    /// Video composition that runs every frame through `state`.
    public static func make(asset: AVAsset, state: RenderState, canvas: Size2) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let timeMs = request.compositionTime.seconds * 1000
            let image = state.render(source: request.sourceImage, timeMs: timeMs)
            request.finish(with: image, context: nil)
        }
        composition.renderSize = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        return composition
    }
}

public enum ExportError: LocalizedError {
    case cannotCreateSession
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateSession: return "Could not create the export session."
        case .failed(let message): return message
        }
    }
}

public enum VideoExporter {
    /// Renders the project to an MP4 file (video composition + source audio tracks).
    public static func export(
        project: Project,
        videoURL: URL,
        to outputURL: URL,
        cursor: CursorAsset? = CursorAsset.defaultArrow(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let state = RenderState(project: project, cursor: cursor)
        let composition = try await CompositionFactory.make(asset: asset, state: state, canvas: project.style.canvas)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = composition
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let monitor = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        progress(1)
    }
}
