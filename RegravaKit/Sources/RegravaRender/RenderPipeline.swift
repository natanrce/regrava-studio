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

/// The recording rearranged into playback time, plus how its audio is mixed.
public struct PlaybackMedia: @unchecked Sendable {
    public let asset: AVAsset
    public let audioMix: AVAudioMix?
}

/// The recording rearranged into playback time: each clip's source range, in order, scaled
/// to its speed (gaps between clips are left out). Composition time is playback time.
public enum PlaybackComposition {
    public static func make(asset: AVAsset, slices: [Slice]) async throws -> AVAsset {
        try await composition(asset: asset, slices: slices, backgroundAudio: nil, playbackDurationMs: 0) ?? asset
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
            asset: asset, slices: project.slices, backgroundAudio: backgroundURL, playbackDurationMs: resolver.playbackDurationMs
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
    private static func composition(asset: AVAsset, slices: [Slice], backgroundAudio: URL?, playbackDurationMs: Double) async throws -> AVAsset? {
        let duration = try await asset.load(.duration)
        let durationMs = duration.seconds * 1000
        if backgroundAudio == nil, slices.count == 1, let only = slices.first, only.timeScale == 1, only.sourceStartMs <= 0, only.sourceEndMs >= durationMs - 1 {
            return nil
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
