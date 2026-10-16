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

    public init(project: Project, cursors: CursorLibrary? = CursorLibrary.arrowOnly(), assetsDirectory: URL? = nil) {
        snapshot = Self.makeSnapshot(project: project, cursors: cursors, assetsDirectory: assetsDirectory)
    }

    /// `assetsDirectory` is the project folder (background images).
    public static func makeSnapshot(project: Project, cursors: CursorLibrary?, assetsDirectory: URL? = nil) -> Snapshot {
        let track = CameraTrack(project: project)
        let compositor = FrameCompositor(project: project, layout: track.layout, cursors: cursors, assetsDirectory: assetsDirectory)
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
    ///
    /// Frames are composed at canvas size and then scaled to `outputSize` (defaults to the
    /// canvas). `fps` sets the composition frame rate (defaults to the source's).
    public static func make(
        asset: AVAsset,
        state: RenderState,
        canvas: Size2,
        outputSize: Size2? = nil,
        fps: Int? = nil
    ) async throws -> AVMutableVideoComposition {
        let output = outputSize ?? canvas
        let scaleX = output.width / max(canvas.width, 1)
        let scaleY = output.height / max(canvas.height, 1)
        let outputRect = CGRect(x: 0, y: 0, width: output.width.rounded(), height: output.height.rounded())
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let timeMs = request.compositionTime.seconds * 1000
            var image = state.render(source: request.sourceImage, timeMs: timeMs)
            if scaleX != 1 || scaleY != 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: outputRect)
            }
            request.finish(with: image, context: nil)
        }
        composition.renderSize = outputRect.size
        if let fps { composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps)) }
        return composition
    }
}

/// The recording rearranged into playback time: each clip's source range, in order, scaled
/// to its speed (gaps between clips are left out). Composition time is playback time.
public enum PlaybackComposition {
    public static func make(asset: AVAsset, slices: [Slice]) async throws -> AVAsset {
        let duration = try await asset.load(.duration)
        let durationMs = duration.seconds * 1000
        // One untouched clip: play the file directly.
        if slices.count == 1, let only = slices.first, only.timeScale == 1, only.sourceStartMs <= 0, only.sourceEndMs >= durationMs - 1 {
            return asset
        }
        let composition = AVMutableComposition()
        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                target.preferredTransform = try await track.load(.preferredTransform)
                var cursor = CMTime.zero
                for slice in slices {
                    let start = CMTime(seconds: max(slice.sourceStartMs, 0) / 1000, preferredTimescale: 600)
                    let end = CMTime(seconds: min(slice.sourceEndMs, durationMs) / 1000, preferredTimescale: 600)
                    guard end > start else { continue }
                    let range = CMTimeRange(start: start, end: end)
                    try target.insertTimeRange(range, of: track, at: cursor)
                    let scaled = CMTime(seconds: range.duration.seconds * slice.timeScale, preferredTimescale: 600)
                    if scaled != range.duration {
                        target.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
                    }
                    cursor = cursor + scaled
                }
            }
        }
        return composition
    }
}
