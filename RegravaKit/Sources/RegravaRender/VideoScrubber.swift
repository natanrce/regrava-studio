import AVFoundation
import CoreImage
import Foundation
import RegravaCore

/// Frames of a movie decoded around a moving demand: setting the demand is cheap, one decode
/// stream runs at a time and only restarts at a keyframe when the demand leaves it, up to 36
/// frames stay cached, 6 are decoded ahead, and a frame that has not landed yet shows as the
/// nearest decoded one.
public final class VideoScrubber: @unchecked Sendable {
    public static let cachedFrames = 36
    public static let framesAhead = 6

    private struct Frame {
        var ms: Double
        var buffer: CVPixelBuffer
        /// The next frame of the same decode stream, once it has been read.
        var nextMs: Double?
    }

    private let asset: AVURLAsset
    private let queue = DispatchQueue(label: "regrava.scrubber", qos: .userInteractive)
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var demandMs: Double = 0
    private var isPumping = false
    private var isClosed = false

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Time in ms of the stream's last frame.
    private var streamLastMs: Double?
    private var streamEnded = false
    private var track: AVAssetTrack?
    private var durationMs: Double = 0
    private var frameMs: Double = 1000.0 / 60
    /// Presentation times of the sync samples, ascending.
    private var keyframesMs: [Double] = []

    /// A frame landed (any thread).
    public var onFrame: (@Sendable () -> Void)?

    public init(url: URL) {
        asset = AVURLAsset(url: url)
    }

    /// The time shown now, in ms of the movie. Cheap: call on every change.
    public func demand(_ ms: Double) {
        lock.lock()
        demandMs = ms
        let start = !isPumping && !isClosed
        if start { isPumping = true }
        lock.unlock()
        if start { queue.async { self.pump() } }
    }

    public func close() {
        lock.lock()
        isClosed = true
        frames.removeAll()
        lock.unlock()
        queue.async {
            self.reader?.cancelReading()
            self.reader = nil
        }
    }

    /// The decoded frame shown at `ms`: the last one at or before it, else the first after it.
    public func frame(at ms: Double) -> (buffer: CVPixelBuffer, ms: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        if let before = frames.last(where: { $0.ms <= ms + 0.5 }) { return (before.buffer, before.ms) }
        return frames.first.map { ($0.buffer, $0.ms) }
    }

    // MARK: Decoding (on `queue`)

    private func pump() {
        if track == nil { loadTrack() }
        while true {
            lock.lock()
            let target = demandMs
            if isClosed || track == nil {
                isPumping = false
                lock.unlock()
                return
            }
            let covered = isCovered(target)
            let wantsAhead = covered && streamContains(target) && !streamEnded && (streamLastMs ?? .infinity) < target + Double(Self.framesAhead) * frameMs
            lock.unlock()
            if covered && !wantsAhead {
                lock.lock()
                // Stop unless the demand moved while deciding.
                if demandMs == target {
                    isPumping = false
                    lock.unlock()
                    return
                }
                lock.unlock()
                continue
            }
            if !covered && !canReach(target) { restart(at: target) }
            readOne(target: target)
        }
    }

    private func loadTrack() {
        let semaphore = DispatchSemaphore(value: 0)
        let asset = self.asset
        nonisolated(unsafe) var loaded: (AVAssetTrack?, Double, Float) = (nil, 0, 0)
        Task.detached {
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let rate = (try? await track?.load(.nominalFrameRate)) ?? 0
            loaded = (track, duration * 1000, rate ?? 0)
            semaphore.signal()
        }
        semaphore.wait()
        track = loaded.0
        durationMs = loaded.1
        if loaded.2 > 0 { frameMs = 1000 / Double(loaded.2) }
        if let track, track.canProvideSampleCursors, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            var keys: [Double] = []
            repeat {
                if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { keys.append(cursor.presentationTimeStamp.seconds * 1000) }
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
            keyframesMs = keys.sorted()
        }
    }

    /// A cached frame shows `target` exactly: it is at or before it and its successor is after it.
    private func isCovered(_ target: Double) -> Bool {
        guard let index = frames.lastIndex(where: { $0.ms <= target + 0.5 }) else { return false }
        if let next = frames[index].nextMs { return next > target + 0.5 }
        // The stream's last frame covers everything after it once the stream ended at the end.
        return streamEnded && frames[index].ms == streamLastMs && streamLastMs != nil
    }

    private func streamContains(_ target: Double) -> Bool {
        guard reader != nil, let last = streamLastMs else { return false }
        return frames.contains { $0.ms <= target + 0.5 } && last >= target - 2000
    }

    /// The running stream gets to `target` by reading on: it is before it and no keyframe lies
    /// between, else decoding again from the target's keyframe is sooner.
    private func canReach(_ target: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard reader != nil, !streamEnded else { return false }
        guard let last = streamLastMs else { return true }
        guard target >= last else { return false }
        if keyframesMs.isEmpty { return target - last < 1000 }
        let keyframe = keyframesMs.last { $0 <= target + 0.5 } ?? 0
        return keyframe <= last + 0.5
    }

    private func restart(at target: Double) {
        reader?.cancelReading()
        reader = nil
        output = nil
        guard let track, let reader = try? AVAssetReader(asset: asset) else { return }
        // The decoder's own 4:2:0 (no conversion pass); Core Image converts it when composing.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        output.alwaysCopiesSampleData = false
        output.supportsRandomAccess = false
        reader.add(output)
        // From the target's keyframe: it lands almost at once and the frames after it walk to the
        // target, each shown as the nearest decoded one meanwhile.
        let clamped = min(target, durationMs)
        let start = keyframesMs.last { $0 <= clamped + 0.5 } ?? max(0, clamped - frameMs)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start / 1000, preferredTimescale: 600), end: .positiveInfinity)
        guard reader.startReading() else { return }
        self.reader = reader
        self.output = output
        lock.lock()
        streamLastMs = nil
        streamEnded = false
        lock.unlock()
    }

    private func readOne(target: Double) {
        guard let output, let reader, reader.status == .reading else {
            lock.lock()
            streamEnded = true
            lock.unlock()
            return
        }
        guard let sample = output.copyNextSampleBuffer() else {
            lock.lock()
            streamEnded = true
            lock.unlock()
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let ms = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
        lock.lock()
        if let last = streamLastMs, let index = frames.lastIndex(where: { $0.ms == last }) {
            frames[index].nextMs = ms
        }
        frames.removeAll { $0.ms == ms }
        var frame = Frame(ms: ms, buffer: buffer)
        // A later cached frame of an older stream is not known to follow this one.
        frame.nextMs = nil
        let insertAt = frames.firstIndex { $0.ms > ms } ?? frames.count
        frames.insert(frame, at: insertAt)
        streamLastMs = ms
        // Keep the frames nearest the demand.
        while frames.count > Self.cachedFrames {
            let center = demandMs
            if abs(frames[0].ms - center) > abs(frames[frames.count - 1].ms - center) { frames.removeFirst() } else { frames.removeLast() }
        }
        let callback = onFrame
        lock.unlock()
        callback?()
    }
}

/// The editor's preview while hover scrubbing: frames come from scrubbers instead of player
/// seeks, and each demand composes the nearest decoded frames at once, so it never waits.
public final class ScrubPreview: @unchecked Sendable {
    private let state: RenderState
    private let screen: VideoScrubber
    private let camera: VideoScrubber?
    private let cameraOffsetMs: Double
    private let resolver: TimeResolver
    private let canvas: Size2
    private let output: CGSize
    private let renderQueue = DispatchQueue(label: "regrava.scrub-render", qos: .userInteractive)
    private let lock = NSLock()
    private var playbackMs: Double?
    private var isRendering = false
    private var needsRender = false
    private var lastRendered: (Double, Double, Double?)?
    private var pool: CVPixelBufferPool?

    /// A composed frame for the preview (main thread).
    public var onImage: (@MainActor @Sendable (CVPixelBuffer) -> Void)?

    public init(state: RenderState, screenURL: URL, cameraURL: URL?, cameraOffsetMs: Double, resolver: TimeResolver, canvas: Size2, output: Size2) {
        self.state = state
        screen = VideoScrubber(url: screenURL)
        camera = cameraURL.map { VideoScrubber(url: $0) }
        self.cameraOffsetMs = cameraOffsetMs
        self.resolver = resolver
        self.canvas = canvas
        self.output = CGSize(width: output.width.rounded(), height: output.height.rounded())
        let render: @Sendable () -> Void = { [weak self] in self?.requestRender() }
        screen.onFrame = render
        camera?.onFrame = render
    }

    public func show(playbackMs: Double) {
        let sourceMs = resolver.playbackToSource(playbackMs)
        screen.demand(sourceMs)
        camera?.demand(max(0, sourceMs + cameraOffsetMs))
        lock.lock()
        self.playbackMs = playbackMs
        lock.unlock()
        requestRender()
    }

    /// The project's look changed: compose the shown frame again.
    public func refresh() {
        lock.lock()
        lastRendered = nil
        lock.unlock()
        requestRender()
    }

    public func close() {
        screen.close()
        camera?.close()
        onImage = nil
    }

    /// Coalesced: one render at a time, then one more with the latest demand.
    private func requestRender() {
        lock.lock()
        if isRendering {
            needsRender = true
            lock.unlock()
            return
        }
        isRendering = true
        lock.unlock()
        renderQueue.async { self.renderLoop() }
    }

    private func renderLoop() {
        while true {
            render()
            lock.lock()
            if needsRender {
                needsRender = false
                lock.unlock()
                continue
            }
            isRendering = false
            lock.unlock()
            return
        }
    }

    private func render() {
        lock.lock()
        let playbackMs = self.playbackMs
        lock.unlock()
        guard let playbackMs else { return }
        let sourceMs = resolver.playbackToSource(playbackMs)
        guard let screenFrame = screen.frame(at: sourceMs) else { return }
        let cameraFrame = camera?.frame(at: max(0, sourceMs + cameraOffsetMs))
        let key = (playbackMs, screenFrame.ms, cameraFrame?.ms)
        lock.lock()
        if let last = lastRendered, last.0 == key.0, last.1 == key.1, last.2 == key.2 {
            lock.unlock()
            return
        }
        lastRendered = key
        lock.unlock()
        guard let buffer = makeBuffer() else { return }
        var image = state.render(source: CIImage(cvPixelBuffer: screenFrame.buffer), camera: cameraFrame.map { CIImage(cvPixelBuffer: $0.buffer) }, timeMs: playbackMs)
        let scaleX = output.width / max(canvas.width, 1), scaleY = output.height / max(canvas.height, 1)
        if scaleX != 1 || scaleY != 1 { image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)) }
        let bounds = CGRect(origin: .zero, size: output)
        CanvasCompositor.context.render(image.cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: CanvasCompositor.sRGB)
        // Tagged, so the layer showing it matches the player's colours.
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CanvasCompositor.sRGB, .shouldPropagate)
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, CGColorSpace.sRGB)
        }
        nonisolated(unsafe) let result = buffer
        let callback = onImage
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(result) } }
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(output.width),
                kCVPixelBufferHeightKey as String: Int(output.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
