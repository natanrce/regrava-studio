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
    /// Finishes the webcam's face detection before rendering when face tracking is on.
    public static func completeFaceTracking(project: Project, bundle: URL) async throws {
        guard project.camera.enableFaceTracking, let name = project.recording.cameraFileName else { return }
        let movie = bundle.appendingPathComponent(name)
        let existing = CameraFaces.load(bundle: bundle)
        guard existing?.isComplete != true, FileManager.default.fileExists(atPath: movie.path) else { return }
        let faces = try await CameraFaceDetector.detect(movie: movie, previous: existing)
        try faces.save(bundle: bundle)
    }

    /// Finishes the hover detection before rendering while the cursor follows hovers: export
    /// frames wait for it ("detecting cursor hovers").
    public static func completeHoverDetection(project: Project, bundle: URL) async throws {
        guard project.cursor.followRecordedPositionOnHover, project.animation.mouseSpring != nil,
              CursorHovers.load(bundle: bundle)?.covers(durationMs: project.recording.durationMs) != true else { return }
        let video = bundle.appendingPathComponent(project.recording.videoFileName)
        guard FileManager.default.fileExists(atPath: video.path) else { return }
        let times = try await CursorHoverDetector.detect(video: video, events: project.mouseEvents, pointPixelScale: project.recording.pointPixelScale)
        try CursorHovers(chunks: [.init(startMs: 0, endMs: project.recording.durationMs, result: times)]).save(bundle: bundle)
    }

    /// Hide sensitive data / Hide faces: an export waits for the whole scan, so only final
    /// detections are drawn (`isSensitiveDataStale` cannot happen then).
    public static func completeSensitiveDataScan(project: Project, bundle: URL) async throws {
        let processing = project.processing
        guard processing.isAutoMasking else { return }
        if let stored = SensitiveDataScan.load(bundle: bundle), stored.isComplete, stored.matches(processing) { return }
        let video = bundle.appendingPathComponent(project.recording.videoFileName)
        guard FileManager.default.fileExists(atPath: video.path) else { return }
        let detections = try await SensitiveDataScanner.scan(video: video, phrases: processing.sensitiveDataCustomPhrases, detectFaces: processing.autoMaskFaces, bundle: bundle) { _, _ in }
        try SensitiveDataScan(customPhrases: processing.sensitiveDataCustomPhrases, detectFaces: processing.autoMaskFaces, detections: detections,
                              finalUpToMs: project.recording.durationMs, isComplete: true).save(bundle: bundle)
    }

    /// Exports and returns the written files (two files for codec "Both").
    @discardableResult
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
        let outputSize = settings.outputSize(aspectRatio: project.stageAspectRatio)
        // Export frames wait until face data covers them ("tracking face").
        try await completeFaceTracking(project: project, bundle: videoURL.deletingLastPathComponent())
        try await completeHoverDetection(project: project, bundle: videoURL.deletingLastPathComponent())
        try await completeSensitiveDataScan(project: project, bundle: videoURL.deletingLastPathComponent())
        // And for the microphone's silences when the camera hides during them.
        try await SilenceAnalyzer.ensure(project: project, bundle: videoURL.deletingLastPathComponent(), recording: videoURL)
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

    /// BT.709 colour tags written on every exported video stream.
    static let colorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// ProRes: the profile's codec. MP4: the hardware encoder at the quality's bitrate (H.264's
    /// constant rate factor converts to its fallback bitrate there), a keyframe at least every
    /// two seconds, High (H.264) or Main (HEVC) profile at an automatic level.
    static func videoOutputSettings(settings: ExportSettings, codec: ExportCodec?, size: Size2) -> [String: Any] {
        var output: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: colorProperties,
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
        let codec = codec ?? .h264
        let isHEVC = codec == .h265
        let bitsPerSecond = ExportEncoding.hardwareBitsPerSecond(codec: codec, quality: settings.quality, width: size.width, height: size.height, fps: settings.fps)
        output[AVVideoCodecKey] = isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        output[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: Int(bitsPerSecond),
            AVVideoMaxKeyFrameIntervalKey: ExportEncoding.maxKeyFrameInterval(fps: settings.fps),
            AVVideoProfileLevelKey: isHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
        ] as [String: Any]
        return output
    }

    /// MP4: AAC at 192 kbps for delivery. ProRes: uncompressed 24-bit PCM, what editing formats
    /// carry. Both 48 kHz stereo.
    static func audioOutputSettings(format: ExportFormat) -> [String: Any] {
        if format == .prores {
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: ExportEncoding.audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: ExportEncoding.pcmBitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: ExportEncoding.audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: ExportEncoding.aacBitsPerSecond,
        ]
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

        // Composed at the export frame rate: every frame drawn is a frame written.
        let composition = try await CompositionFactory.make(
            asset: asset, state: state, canvas: project.canvasSize, outputSize: outputSize, fps: settings.fps
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
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: ExportEncoding.audioSampleRate,
                AVNumberOfChannelsKey: 2,
            ])
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
        // The index goes first, so the movie plays while it downloads.
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(settings: settings, codec: codec, size: outputSize))
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings(format: settings.format))
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
        guard !videoTracks.isEmpty else { throw ExportError.cannotRead("no video track") }

        // Composed at the GIF frame rate, one frame every 1/fps from 0. ImageIO needs the exact
        // image count up front.
        let fps = max(settings.fps, 1)
        let kept = (0..<Int((duration * Double(fps)).rounded(.up))).map { Double($0) / Double(fps) }.filter { $0 < duration - 0.0005 }
        guard !kept.isEmpty else { throw ExportError.cannotRead("no frames") }

        let composition = try await CompositionFactory.make(
            asset: asset, state: state, canvas: project.canvasSize, outputSize: outputSize, fps: fps
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
