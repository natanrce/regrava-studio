import AVFoundation
import CoreImage
import ImageIO
import RegravaCore
import UniformTypeIdentifiers
import VideoToolbox

public enum ExportError: LocalizedError {
    case cannotRead(String)
    case cannotWrite(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let message): return "Could not read the recording: \(message)"
        case .cannotWrite(let message): return "Could not write the export: \(message)"
        case .cancelled: return "Export was stopped."
        }
    }
}

/// Renders a project with the export settings (format, codec, profile, resolution, frame
/// rate, quality) using AVAssetReader/AVAssetWriter, or ImageIO for GIF.
public enum ProjectExporter {
    /// Bits per pixel per frame used for H.264 at each quality. These are this project's choices.
    public static func bitsPerPixel(_ quality: ExportQuality) -> Double {
        switch quality {
        case .studio: return 0.30
        case .socialMedia: return 0.12
        case .webHigh: return 0.07
        case .webLow: return 0.035
        }
    }

    /// Exports and returns the written files (two files for codec "Both").
    @discardableResult
    /// Finishes the webcam's face detection before rendering when face tracking is on.
    public static func completeFaceTracking(project: Project, bundle: URL) async throws {
        guard project.camera.enableFaceTracking, let name = project.recording.cameraFileName else { return }
        let movie = bundle.appendingPathComponent(name)
        let existing = CameraFaces.load(bundle: bundle)
        guard existing?.isComplete != true, FileManager.default.fileExists(atPath: movie.path) else { return }
        let faces = try await CameraFaceDetector.detect(movie: movie, previous: existing)
        try faces.save(bundle: bundle)
    }

    public static func export(
        project: Project,
        videoURL: URL,
        settings rawSettings: ExportSettings,
        target: ExportTarget = .file,
        to outputURL: URL,
        cursors: CursorLibrary? = CursorLibrary.arrowOnly(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        let settings = rawSettings.normalized(target: target)
        let outputSize = settings.outputSize(canvas: project.canvasSize)
        // Export frames wait until face data covers them ("tracking face").
        try await completeFaceTracking(project: project, bundle: videoURL.deletingLastPathComponent())
        let state = RenderState(project: project, cursors: cursors, assetsDirectory: videoURL.deletingLastPathComponent())

        switch settings.format {
        case .gif:
            try await writeGIF(project: project, videoURL: videoURL, settings: settings, outputSize: outputSize, state: state, to: outputURL, progress: progress)
            return [outputURL]
        case .prores:
            try await writeMovie(project: project, videoURL: videoURL, settings: settings, codec: nil, outputSize: outputSize, state: state, to: outputURL, progress: progress)
            return [outputURL]
        case .mp4:
            switch settings.codec {
            case .h264, .h265:
                try await writeMovie(project: project, videoURL: videoURL, settings: settings, codec: settings.codec, outputSize: outputSize, state: state, to: outputURL, progress: progress)
                return [outputURL]
            case .both:
                let hevcURL = outputURL.deletingPathExtension()
                    .appendingPathExtension("hevc")
                    .appendingPathExtension(outputURL.pathExtension)
                try await writeMovie(project: project, videoURL: videoURL, settings: settings, codec: .h264, outputSize: outputSize, state: state, to: outputURL) { progress($0 * 0.5) }
                try await writeMovie(project: project, videoURL: videoURL, settings: settings, codec: .h265, outputSize: outputSize, state: state, to: hevcURL) { progress(0.5 + $0 * 0.5) }
                return [outputURL, hevcURL]
            }
        }
    }

    // MARK: Movie (MP4 / ProRes)

    private static func videoOutputSettings(settings: ExportSettings, codec: ExportCodec?, size: Size2) -> [String: Any] {
        var output: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        if settings.format == .prores {
            switch settings.proresProfile {
            case .lt: output[AVVideoCodecKey] = AVVideoCodecType.proRes422LT
            case .standard: output[AVVideoCodecKey] = AVVideoCodecType.proRes422
            case .hq: output[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
            case .p4444: output[AVVideoCodecKey] = AVVideoCodecType.proRes4444
            }
            return output
        }
        let isHEVC = codec == .h265
        let bitsPerSecond = bitsPerPixel(settings.quality) * (isHEVC ? 0.6 : 1) * size.width * size.height * Double(settings.fps)
        output[AVVideoCodecKey] = isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitsPerSecond),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
        ]
        if !isHEVC { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        output[AVVideoCompressionPropertiesKey] = compression
        return output
    }

    private static func writeMovie(
        project: Project,
        videoURL: URL,
        settings: ExportSettings,
        codec: ExportCodec?,
        outputSize: Size2,
        state: RenderState,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: videoURL.deletingLastPathComponent()))
        let asset = media.asset
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw ExportError.cannotRead("no video track") }

        let composition = try await CompositionFactory.make(
            asset: asset, state: state, canvas: project.canvasSize, outputSize: outputSize
        )

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ExportError.cannotRead(error.localizedDescription) }
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.audioTimePitchAlgorithm = .spectral
            output.audioMix = media.audioMix
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format == .prores ? .mov : .mp4)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(settings: settings, codec: codec, size: outputSize))
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error") }
        guard writer.startWriting() else { throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown error") }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.001)
        let cancelled = CancellationFlag()

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                let limiter = FrameRateLimiter(fps: settings.fps)
                group.addTask {
                    await pump(input: videoInput, output: videoOutput, reader: reader, cancelled: cancelled, label: "video") { buffer in
                        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        progress(min(time / totalSeconds, 0.999))
                        return limiter.keep(time)
                    }
                }
                if let audioInput, let audioOutput {
                    group.addTask {
                        await pump(input: audioInput, output: audioOutput, reader: reader, cancelled: cancelled, label: "audio") { _ in true }
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }

        if cancelled.isSet || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    /// Feeds samples from a reader output to a writer input until done or cancelled.
    private static func pump(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        reader: AVAssetReader,
        cancelled: CancellationFlag,
        label: String,
        shouldAppend: @escaping @Sendable (CMSampleBuffer) -> Bool
    ) async {
        let queue = DispatchQueue(label: "regrava.export.\(label)")
        let once = CancellationFlag()
        // AVFoundation's reader and writer objects are used only on `queue` here.
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let reader = reader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if cancelled.isSet || reader.status != .reading {
                        input.markAsFinished()
                        if once.setIfUnset() { continuation.resume() }
                        return
                    }
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if once.setIfUnset() { continuation.resume() }
                        return
                    }
                    guard shouldAppend(buffer) else { continue }
                    if !input.append(buffer) {
                        input.markAsFinished()
                        if once.setIfUnset() { continuation.resume() }
                        return
                    }
                }
            }
        }
    }

    // MARK: GIF

    private static func writeGIF(
        project: Project,
        videoURL: URL,
        settings: ExportSettings,
        outputSize: Size2,
        state: RenderState,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = try await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: videoURL.deletingLastPathComponent())).asset
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let firstTrack = videoTracks.first else { throw ExportError.cannotRead("no video track") }

        // Pass 1 (no decoding): which source frames are kept at the target frame rate.
        // ImageIO needs the exact image count up front.
        let kept = FrameRateLimiter.select(times: try sourceFrameTimes(asset: asset, track: firstTrack), fps: settings.fps, duration: duration)
        guard !kept.isEmpty else { throw ExportError.cannotRead("no frames") }

        let composition = try await CompositionFactory.make(
            asset: asset, state: state, canvas: project.canvasSize, outputSize: outputSize
        )
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        reader.add(output)

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, kept.count, nil) else {
            throw ExportError.cannotWrite("could not create GIF file")
        }
        var fileProperties: [CFString: Any] = [:]
        if !settings.gifDisableLoop {
            fileProperties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFLoopCount: 0]
        }
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // GIF delays are centiseconds; derive each from rounded cumulative times so the total
        // duration does not drift. The last frame lasts until the end of the video.
        func properties(index: Int) -> CFDictionary {
            let start = (kept[index] * 100).rounded()
            let end = ((index + 1 < kept.count ? kept[index + 1] : duration) * 100).rounded()
            let delay = max(end - start, 1) / 100
            return [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary
        }

        guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error") }
        var written = 0
        var lastImage: CGImage?
        while written < kept.count, let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: outputURL)
                throw ExportError.cancelled
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard abs(time - kept[written]) < 0.0005 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            guard let image else { continue }
            CGImageDestinationAddImage(destination, image, properties(index: written))
            lastImage = image
            written += 1
            progress(min(Double(written) / Double(kept.count), 0.999))
        }
        reader.cancelReading()
        if reader.status == .failed { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error") }
        // Should not happen; keeps the declared count valid if a frame failed to convert.
        if let lastImage {
            while written < kept.count {
                CGImageDestinationAddImage(destination, lastImage, properties(index: written))
                written += 1
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotWrite("could not finalize GIF") }
        progress(1)
    }

    /// Presentation times of the source frames, read without decoding.
    static func sourceFrameTimes(asset: AVAsset, track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error") }
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            }
        }
        return times.sorted()
    }
}

/// Drops frames to reach a target frame rate (never duplicates frames).
final class FrameRateLimiter: @unchecked Sendable {
    private let interval: Double
    private var nextTime = 0.0

    init(fps: Int) {
        interval = 1 / Double(max(fps, 1))
    }

    /// Whether a frame at `time` should be kept.
    func keep(_ time: Double) -> Bool {
        guard time + 0.0005 >= nextTime else { return false }
        while nextTime <= time + 0.0005 { nextTime += interval }
        return true
    }

    static func select(times: [Double], fps: Int, duration: Double) -> [Double] {
        let limiter = FrameRateLimiter(fps: fps)
        return times.filter { $0 < duration - 0.0005 && limiter.keep($0) }
    }
}

/// Thread-safe one-way flag.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    /// Sets the flag; returns true only for the first caller.
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
