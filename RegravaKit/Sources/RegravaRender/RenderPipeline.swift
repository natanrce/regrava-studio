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

    public func render(source: CIImage, camera: CIImage? = nil, timeMs: Double) -> CIImage {
        let s = current
        return s.compositor.compose(source: source, camera: camera, frame: s.track.frame(at: timeMs))
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
    ) async throws -> AVVideoComposition {
        AVVideoComposition(configuration: try await configuration(asset: asset, state: state, canvas: canvas, outputSize: outputSize, fps: fps))
    }

    /// The composition's configuration: a single instruction over the whole asset, rendered
    /// by `CanvasCompositor` at the output size.
    public static func configuration(
        asset: AVAsset,
        state: RenderState,
        canvas: Size2,
        outputSize: Size2? = nil,
        fps: Int? = nil
    ) async throws -> AVVideoComposition.Configuration {
        let output = outputSize ?? canvas
        let renderSize = CGSize(width: output.width.rounded(), height: output.height.rounded())
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var rate = Float(fps ?? 0)
        if rate <= 0, let track = tracks.first { rate = try await track.load(.nominalFrameRate) }
        if rate <= 0 { rate = 60 }
        // The screen is the first video track; the webcam, when present, the second.
        let instruction = CanvasInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            trackID: tracks.first?.trackID ?? kCMPersistentTrackID_Invalid,
            cameraTrackID: tracks.count > 1 ? tracks[1].trackID : nil,
            state: state,
            canvas: canvas,
            renderSize: renderSize
        )
        return AVVideoComposition.Configuration(
            customVideoCompositorClass: CanvasCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(rate.rounded())),
            instructions: [instruction],
            renderSize: renderSize
        )
    }
}

/// Instruction carrying what `CanvasCompositor` needs to draw a frame.
final class CanvasInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let state: RenderState
    let canvas: Size2
    let renderSize: CGSize

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, state: RenderState, canvas: Size2, renderSize: CGSize) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.cameraTrackID = cameraTrackID
        self.state = state
        self.canvas = canvas
        self.renderSize = renderSize
        requiredSourceTrackIDs = ([trackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Renders each frame with Core Image on the GPU (Metal) at canvas size, scaled to the
/// output size.
final class CanvasCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CanvasInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "RegravaRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing frame"]))
            return
        }
        let timeMs = request.compositionTime.seconds * 1000
        let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
        var image = instruction.state.render(source: CIImage(cvPixelBuffer: source), camera: camera, timeMs: timeMs)
        let scaleX = instruction.renderSize.width / max(instruction.canvas.width, 1)
        let scaleY = instruction.renderSize.height / max(instruction.canvas.height, 1)
        if scaleX != 1 || scaleY != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        let bounds = CGRect(origin: .zero, size: instruction.renderSize)
        Self.context.render(image.cropped(to: bounds), to: output, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// The recording rearranged into playback time, plus how its audio is mixed.
public struct PlaybackMedia: @unchecked Sendable {
    public let asset: AVAsset
    public let audioMix: AVAudioMix?
}

/// The recording rearranged into playback time: each clip's source range, in order, scaled
/// to its speed (gaps between clips are left out). Composition time is playback time.
public enum PlaybackComposition {
    public static func make(asset: AVAsset, slices: [Slice]) async throws -> AVAsset {
        try await composition(asset: asset, slices: slices, camera: nil, backgroundAudio: nil, playbackDurationMs: 0) ?? asset
    }

    /// The webcam movie of a project: saved beside the screen recording.
    static func cameraAsset(project: Project, recording: AVAsset) -> AVAsset? {
        guard let name = project.recording.cameraFileName, let screen = (recording as? AVURLAsset)?.url else { return nil }
        let url = screen.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? AVURLAsset(url: url) : nil
    }

    /// The playable media for a project: each recorded source at its clip volumes unless
    /// muted, and the background audio repeated until the end.
    public static func media(asset: AVAsset, project: Project, assetsDirectory: URL?) async throws -> PlaybackMedia {
        let audio = project.audio
        var backgroundURL: URL?
        if let name = audio.backgroundAudioFileName, !audio.muteBackgroundAudio, audio.backgroundAudioVolume > 0, let assetsDirectory {
            let url = assetsDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { backgroundURL = url }
        }
        let resolver = project.resolver
        let playable = try await composition(
            asset: asset, slices: project.slices, camera: cameraAsset(project: project, recording: asset),
            backgroundAudio: backgroundURL, playbackDurationMs: resolver.playbackDurationMs
        ) ?? asset
        let tracks = try await playable.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return PlaybackMedia(asset: playable, audioMix: nil) }
        let sources = project.recording.audioSources
        var parameters: [AVAudioMixInputParameters] = []
        for (index, track) in tracks.enumerated() {
            let input = AVMutableAudioMixInputParameters(track: track)
            if backgroundURL != nil && index == tracks.count - 1 && playable !== asset {
                input.setVolume(Float(audio.backgroundAudioVolume * audio.volume), at: .zero)
            } else if index < sources.count {
                let source = sources[index]
                if audio.isMuted(source) {
                    input.setVolume(0, at: .zero)
                } else {
                    for (slice, link) in zip(project.slices, resolver.links) {
                        let at = CMTime(seconds: link.playbackStartMs / 1000, preferredTimescale: 600)
                        input.setVolume(Float(slice.volume(for: source) * audio.volume), at: at)
                    }
                }
            } else {
                input.setVolume(Float(audio.volume), at: .zero)
            }
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return PlaybackMedia(asset: playable, audioMix: mix)
    }

    /// nil when the file can be played as it is.
    private static func composition(asset: AVAsset, slices: [Slice], camera: AVAsset?, backgroundAudio: URL?, playbackDurationMs: Double) async throws -> AVAsset? {
        let duration = try await asset.load(.duration)
        let durationMs = duration.seconds * 1000
        if backgroundAudio == nil, camera == nil, slices.count == 1, let only = slices.first, only.timeScale == 1, only.sourceStartMs <= 0, only.sourceEndMs >= durationMs - 1 {
            return nil
        }
        let composition = AVMutableComposition()
        /// Each clip's source range, in order, scaled to its speed. A shorter source (the webcam)
        /// keeps the playback timing: missing parts are left empty.
        func insertSliced(_ track: AVAssetTrack, type: AVMediaType, sourceDurationMs: Double) async throws {
            guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            target.preferredTransform = try await track.load(.preferredTransform)
            var cursor = CMTime.zero
            for slice in slices {
                let start = CMTime(seconds: max(slice.sourceStartMs, 0) / 1000, preferredTimescale: 600)
                let end = CMTime(seconds: min(slice.sourceEndMs, durationMs) / 1000, preferredTimescale: 600)
                guard end > start else { continue }
                let range = CMTimeRange(start: start, end: end)
                let scaled = CMTime(seconds: range.duration.seconds * slice.timeScale, preferredTimescale: 600)
                let available = CMTimeRange(start: start, end: CMTimeMinimum(end, CMTime(seconds: sourceDurationMs / 1000, preferredTimescale: 600)))
                if available.duration > .zero {
                    try target.insertTimeRange(available, of: track, at: cursor)
                    let scaledAvailable = CMTime(seconds: available.duration.seconds * slice.timeScale, preferredTimescale: 600)
                    if scaledAvailable != available.duration {
                        target.scaleTimeRange(CMTimeRange(start: cursor, duration: available.duration), toDuration: scaledAvailable)
                    }
                }
                cursor = cursor + scaled
            }
        }
        for track in try await asset.loadTracks(withMediaType: .video) {
            try await insertSliced(track, type: .video, sourceDurationMs: durationMs)
        }
        if let camera, let track = try await camera.loadTracks(withMediaType: .video).first {
            try await insertSliced(track, type: .video, sourceDurationMs: try await camera.load(.duration).seconds * 1000)
        }
        for track in try await asset.loadTracks(withMediaType: .audio) {
            try await insertSliced(track, type: .audio, sourceDurationMs: durationMs)
        }
        // Background audio, repeated until the end (`repeatUntilMs`).
        if let backgroundAudio {
            let music = AVURLAsset(url: backgroundAudio)
            if let source = try await music.loadTracks(withMediaType: .audio).first,
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let length = try await music.load(.duration)
                let end = CMTime(seconds: playbackDurationMs / 1000, preferredTimescale: 600)
                var cursor = CMTime.zero
                while length.seconds > 0.01 && cursor < end {
                    let piece = CMTimeMinimum(length, end - cursor)
                    try target.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: source, at: cursor)
                    cursor = cursor + piece
                }
            }
        }
        return composition
    }
}
