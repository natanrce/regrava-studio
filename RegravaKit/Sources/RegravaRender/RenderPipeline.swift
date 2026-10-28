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
        let faces = project.camera.enableFaceTracking ? assetsDirectory.flatMap(CameraFaces.load(bundle:)) : nil
        let silence = assetsDirectory.flatMap { SilenceAnalyzer.stored(project: project, bundle: $0) } ?? []
        let hovers = assetsDirectory.flatMap(CursorHovers.load(bundle:))
        let track = CameraTrack(project: project, faces: faces, silence: silence, hovers: hovers)
        // Captions read the transcript stored beside the project (source time, onset-adjusted).
        let transcript = assetsDirectory.flatMap { SessionTranscript.load(bundle: $0) }
            .map { TranscriptTiming.clientTranscript([(0, $0.transcript)]) } ?? []
        // Hide sensitive data / Hide faces: the detections the scan has so far.
        let sensitiveData = project.processing.isAutoMasking ? (assetsDirectory.flatMap { SensitiveDataScan.load(bundle: $0) }?.detections ?? []) : []
        let compositor = FrameCompositor(project: project, layout: track.layout, cursors: cursors, assetsDirectory: assetsDirectory, transcript: transcript, sensitiveData: sensitiveData)
        return Snapshot(track: track, compositor: compositor)
    }

    public var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    private var _quality: RenderQuality = .export

    /// Playback, paused or export quality of the frames rendered from now on.
    public var quality: RenderQuality {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _quality
        }
        set {
            lock.lock()
            _quality = newValue
            lock.unlock()
        }
    }

    public func replace(with newSnapshot: Snapshot) {
        lock.lock()
        snapshot = newSnapshot
        lock.unlock()
    }

    public func render(source: CIImage, camera: CIImage? = nil, timeMs: Double) -> CIImage {
        let s = current
        return s.compositor.compose(source: source, camera: camera, frame: s.track.frame(at: timeMs), quality: quality)
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

extension CompositionFactory {
    /// Core Image compiles a program the first time it sees a graph, which took 40–1000 ms and
    /// stalled playback whenever a zoom or a cursor trail first needed a new number of motion
    /// blur samples. This draws one moving frame per screen/cursor sample count at playback
    /// quality with the compositor's context, so those programs exist before playing. Stops
    /// early when the calling task is cancelled.
    public static func prewarm(state: RenderState, outputSize: Size2, cameraSize: Size2? = nil) {
        prewarmCutout(state: state, outputSize: outputSize, cameraSize: cameraSize)
        if Task.isCancelled { return }
        let snapshot = state.current
        let compositor = snapshot.compositor
        let strength = compositor.motionBlurStrength
        guard strength > 0 else { return }
        let layout = snapshot.track.layout
        let video = layout.videoSize
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var sourceBuffer: CVPixelBuffer?, outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(video.width), Int(video.height), kCVPixelFormatType_32BGRA, attributes, &sourceBuffer)
        CVPixelBufferCreate(nil, Int(outputSize.width), Int(outputSize.height), kCVPixelFormatType_32BGRA, attributes, &outputBuffer)
        guard let sourceBuffer, let outputBuffer else { return }
        let source = CIImage(cvPixelBuffer: sourceBuffer)
        var base = snapshot.track.frame(at: 0)
        base.isInstantSnap = false
        base.cursorOpacity = 1
        let cursor = base.cursor ?? Vec2(video.width / 2, video.height / 2)
        base.cursor = cursor
        let videoToCanvas = base.screenRect.width / max(video.width, 1)
        let texels = RenderQuality.playing.texelsPerSample
        let counts = [0] + Array(2...RenderQuality.playing.maxSamples)
        let scale = outputSize.width / max(layout.canvas.width, 1)
        let bounds = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        for screenSamples in counts {
            for cursorSamples in counts {
                if Task.isCancelled { return }
                var frame = base
                let screenTravel = screenSamples == 0 ? 0 : (Double(screenSamples) - 0.5) * texels
                var previous = base.screenRect
                previous.x += screenTravel / strength
                frame.previousScreenRect = previous
                let cursorTravel = cursorSamples == 0 ? 0 : (Double(cursorSamples) - 0.5) * texels
                frame.previousCursor = Vec2(cursor.x + cursorTravel / strength / max(videoToCanvas, 0.0001), cursor.y)
                let image = compositor.compose(source: source, frame: frame, quality: .playing)
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                CanvasCompositor.context.render(image.cropped(to: bounds), to: outputBuffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
    }
}

extension CompositionFactory {
    /// The cutout passes and Vision's model for the playing and paused qualities, fully cut out
    /// and mid-reveal, so the first cutout frame does not stall either.
    static func prewarmCutout(state: RenderState, outputSize: Size2, cameraSize: Size2?) {
        let snapshot = state.current
        guard snapshot.compositor.mattesCamera, let cameraSize, cameraSize.width > 0, cameraSize.height > 0 else { return }
        var frame = snapshot.track.frame(at: 0)
        guard frame.cameraRect != nil else { return }
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var screenBuffer: CVPixelBuffer?, cameraBuffer: CVPixelBuffer?, outputBuffer: CVPixelBuffer?
        let video = snapshot.track.layout.videoSize
        CVPixelBufferCreate(nil, Int(video.width), Int(video.height), kCVPixelFormatType_32BGRA, attributes, &screenBuffer)
        CVPixelBufferCreate(nil, Int(cameraSize.width), Int(cameraSize.height), kCVPixelFormatType_32BGRA, attributes, &cameraBuffer)
        CVPixelBufferCreate(nil, Int(outputSize.width), Int(outputSize.height), kCVPixelFormatType_32BGRA, attributes, &outputBuffer)
        guard let screenBuffer, let cameraBuffer, let outputBuffer else { return }
        let scale = outputSize.width / max(snapshot.track.layout.canvas.width, 1)
        let bounds = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        for quality in [RenderQuality.playing, .pausedHigh] {
            for cutout in [1.0, 0.5] {
                if Task.isCancelled { return }
                frame.cameraCutout01 = cutout
                frame.cameraOpacity = 1
                let image = snapshot.compositor.compose(source: CIImage(cvPixelBuffer: screenBuffer), camera: CIImage(cvPixelBuffer: cameraBuffer), frame: frame, quality: quality)
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                CanvasCompositor.context.render(image.cropped(to: bounds), to: outputBuffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
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
    static let context = CIContext(options: [.cacheIntermediates: false])

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    /// The last screen frame, held over gaps in the video track: a recording paused and
    /// resumed can leave a few milliseconds without frames where its sessions join, and
    /// failing those requests would stop playback.
    private var lastSource: CVPixelBuffer?
    private let lock = NSLock()

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CanvasInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "RegravaRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing frame"]))
            return
        }
        lock.lock()
        if let frame = request.sourceFrame(byTrackID: instruction.trackID) { lastSource = frame }
        let held = lastSource
        lock.unlock()
        guard let source = held else {
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
        try await composition(asset: asset, slices: slices, camera: nil, backgroundAudio: nil, clicks: [], playbackDurationMs: 0)?.asset ?? asset
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
        // Click sounds: each at its event's playback time, at speed 1.
        var clicks: [(url: URL, atMs: Double)] = []
        if let set = audio.clickSoundEffect, audio.clickSoundEffectVolume > 0 {
            clicks = project.plannedClickSounds.compactMap { c in BundledSounds.click(set, c.kind).map { ($0, c.playbackTimeMs) } }
        }
        // The microphone plays from its best finished render (`bestReadyPath`): the chosen mode's,
        // else Standard's, else the take itself.
        var microphone: (index: Int, url: URL)?
        if let bundle = assetsDirectory?.deletingLastPathComponent(), let index = project.recording.audioSources.firstIndex(of: .microphone),
           let url = MicrophoneRenderer.bestReadyURL(bundle: bundle, preset: audio.microphoneAudioPreset) {
            microphone = (index, url)
        }
        let built = try await composition(
            asset: asset, slices: project.slices, camera: cameraAsset(project: project, recording: asset),
            cameraOffsetMs: project.camera.delayAdjustmentMs,
            backgroundAudio: backgroundURL, clicks: clicks, microphone: microphone, playbackDurationMs: resolver.playbackDurationMs
        )
        let playable = built?.asset ?? asset
        let tracks = try await playable.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return PlaybackMedia(asset: playable, audioMix: nil) }
        let sources = project.recording.audioSources
        var parameters: [AVAudioMixInputParameters] = []
        for (index, track) in tracks.enumerated() {
            let input = AVMutableAudioMixInputParameters(track: track)
            if let built, track.trackID == built.backgroundTrackID {
                input.setVolume(Float(audio.backgroundAudioVolume * audio.volume), at: .zero)
            } else if let built, built.clickTrackIDs.contains(track.trackID) {
                input.setVolume(Float(audio.clickSoundEffectVolume * audio.volume), at: .zero)
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

    struct Built {
        var asset: AVAsset
        var backgroundTrackID: CMPersistentTrackID?
        var clickTrackIDs: Set<CMPersistentTrackID>
    }

    /// nil when the file can be played as it is.
    private static func composition(asset: AVAsset, slices: [Slice], camera: AVAsset?, cameraOffsetMs: Double = 0, backgroundAudio: URL?, clicks: [(url: URL, atMs: Double)], microphone: (index: Int, url: URL)? = nil, playbackDurationMs: Double) async throws -> Built? {
        let duration = try await asset.load(.duration)
        let durationMs = duration.seconds * 1000
        if backgroundAudio == nil, clicks.isEmpty, camera == nil, microphone == nil, slices.count == 1, let only = slices.first, only.timeScale == 1, only.sourceStartMs <= 0, only.sourceEndMs >= durationMs - 1 {
            return nil
        }
        let composition = AVMutableComposition()
        /// Each clip's source range, in order, scaled to its speed. A shorter source keeps the
        /// playback timing: missing parts are left empty, or, with `holdEdges` (the webcam), filled
        /// with its first or last frame. `offsetMs` shifts the source (camera delay).
        func insertSliced(_ track: AVAssetTrack, type: AVMediaType, sourceDurationMs: Double, offsetMs: Double = 0, holdEdges: Bool = false) async throws {
            guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            target.preferredTransform = try await track.load(.preferredTransform)
            let frameMs = 1000.0 / Double(max(try await track.load(.nominalFrameRate), 1))
            func time(_ ms: Double) -> CMTime { CMTime(seconds: ms / 1000, preferredTimescale: 600) }
            /// Inserts `[startMs, endMs)` of the source stretched to `durationMs` at `atMs`.
            func place(_ startMs: Double, _ endMs: Double, atMs: Double, durationMs: Double) throws {
                guard endMs > startMs, durationMs > 0 else { return }
                let range = CMTimeRange(start: time(startMs), end: time(endMs))
                try target.insertTimeRange(range, of: track, at: time(atMs))
                if abs(range.duration.seconds * 1000 - durationMs) > 0.5 {
                    target.scaleTimeRange(CMTimeRange(start: time(atMs), duration: range.duration), toDuration: time(durationMs))
                }
            }
            var cursorMs = 0.0
            for slice in slices {
                let start = max(slice.sourceStartMs, 0), end = min(slice.sourceEndMs, durationMs)
                guard end > start else { continue }
                let wantStart = start + offsetMs, wantEnd = end + offsetMs
                let lo = max(wantStart, 0), hi = min(wantEnd, sourceDurationMs)
                let headMs = min(max(lo - wantStart, 0), end - start)
                if holdEdges && headMs > 0 && sourceDurationMs > 0 {
                    try place(0, min(frameMs, sourceDurationMs), atMs: cursorMs, durationMs: headMs * slice.timeScale)
                }
                if hi > lo {
                    try place(lo, hi, atMs: cursorMs + headMs * slice.timeScale, durationMs: (hi - lo) * slice.timeScale)
                }
                let tailMs = (end - start) - headMs - max(hi - lo, 0)
                if holdEdges && tailMs > 0.5 && sourceDurationMs > frameMs {
                    let at = cursorMs + (end - start - tailMs) * slice.timeScale
                    try place(sourceDurationMs - frameMs, sourceDurationMs, atMs: at, durationMs: tailMs * slice.timeScale)
                }
                cursorMs += (end - start) * slice.timeScale
            }
        }
        for track in try await asset.loadTracks(withMediaType: .video) {
            try await insertSliced(track, type: .video, sourceDurationMs: durationMs)
        }
        if let camera, let track = try await camera.loadTracks(withMediaType: .video).first {
            // Camera time = recording time + delay, clamped to the movie.
            try await insertSliced(track, type: .video, sourceDurationMs: try await camera.load(.duration).seconds * 1000, offsetMs: cameraOffsetMs, holdEdges: true)
        }
        // Kept alive until the inserts are done.
        let rendered = microphone.map { AVURLAsset(url: $0.url) }
        for (index, track) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
            if index == microphone?.index, let rendered, let replacement = try await rendered.loadTracks(withMediaType: .audio).first {
                // Same timeline as the take, so the same clips apply.
                try await insertSliced(replacement, type: .audio, sourceDurationMs: try await rendered.load(.duration).seconds * 1000)
            } else {
                try await insertSliced(track, type: .audio, sourceDurationMs: durationMs)
            }
        }
        // Background audio, repeated until the end (`repeatUntilMs`).
        var backgroundTrackID: CMPersistentTrackID?
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
                backgroundTrackID = target.trackID
            }
        }
        // Click sounds overlap freely: each goes on the first click track that is free by then.
        var clickTracks: [(track: AVMutableCompositionTrack, endMs: Double)] = []
        // The assets stay referenced until the inserts are done: a track outlives its asset badly.
        var sounds: [URL: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)] = [:]
        for click in clicks.sorted(by: { $0.atMs < $1.atMs }) {
            if sounds[click.url] == nil {
                let file = AVURLAsset(url: click.url)
                if let track = try await file.loadTracks(withMediaType: .audio).first {
                    sounds[click.url] = (file, track, try await track.load(.timeRange))
                }
            }
            guard let sound = sounds[click.url], sound.range.duration.seconds > 0 else { continue }
            // Cut short at the end of the video.
            let remaining = CMTime(seconds: max(playbackDurationMs - click.atMs, 0) / 1000, preferredTimescale: sound.range.duration.timescale)
            let piece = CMTimeRange(start: sound.range.start, duration: CMTimeMinimum(sound.range.duration, remaining))
            guard piece.duration.seconds > 0 else { continue }
            let length = piece.duration.seconds * 1000
            let index: Int
            if let free = clickTracks.firstIndex(where: { $0.endMs <= click.atMs }) {
                index = free
            } else if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                clickTracks.append((track, 0))
                index = clickTracks.count - 1
            } else { continue }
            let at = CMTime(seconds: click.atMs / 1000, preferredTimescale: 44_100)
            try clickTracks[index].track.insertTimeRange(piece, of: sound.track, at: at)
            clickTracks[index].endMs = click.atMs + length
        }
        return Built(asset: composition, backgroundTrackID: backgroundTrackID, clickTrackIDs: Set(clickTracks.map { $0.track.trackID }))
    }
}
