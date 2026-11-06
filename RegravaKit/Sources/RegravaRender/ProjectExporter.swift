import AVFoundation
import CoreImage
import os
import RegravaCore
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
/// rate, quality) using AVAssetReader/AVAssetWriter, or the GIF stream encoder for GIF.
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

    /// Hide sensitive data / Hide faces: an export renders while the scan runs, unless the project
    /// holds the complete result for its inputs. Nil when nothing is to be hidden or the result is
    /// stored.
    static func streamingSensitiveData(project: Project, bundle: URL, video: URL, requesterId: String,
                                       options: SensitiveDataScanner.Options = .init()) -> ExportSensitiveData? {
        let processing = project.processing
        guard processing.isAutoMasking else { return nil }
        if let stored = SensitiveDataScan.load(bundle: bundle), stored.isComplete, stored.matches(processing) { return nil }
        guard FileManager.default.fileExists(atPath: video.path) else { return nil }
        return ExportSensitiveData(project: project, video: video, bundle: bundle, requesterId: requesterId,
                                   firstSourceMs: project.resolver.playbackToSource(0), options: options)
    }

    /// Keeps the scan's complete result in the project.
    static func storeSensitiveDataResult(_ detections: [SensitiveDataDetection], project: Project, bundle: URL) {
        let processing = project.processing
        try? SensitiveDataScan(customPhrases: processing.sensitiveDataCustomPhrases, detectFaces: processing.autoMaskFaces, detections: detections,
                               finalUpToMs: project.recording.durationMs, isComplete: true).save(bundle: bundle)
    }

    private static let log = Logger(subsystem: "com.natanzin.regravastudio", category: "export")

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
        try await export(project: project, videoURL: videoURL, settings: rawSettings, target: target, to: outputURL, cursors: cursors, readsAhead: true, progress: progress)
    }

    /// `readsAhead`: whether the next frame renders while the encoders take the last (off, each
    /// frame renders when an encoder asks for it). Both write the same frames.
    static func export(
        project: Project,
        videoURL: URL,
        settings rawSettings: ExportSettings,
        target: ExportTarget = .file,
        to outputURL: URL,
        cursors: CursorLibrary?,
        readsAhead: Bool,
        sensitiveDataOptions: SensitiveDataScanner.Options = .init(),
        observeSensitiveData: (@Sendable (ExportSensitiveData) -> Void)? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        let settings = rawSettings.normalized(target: target)
        let outputSize = settings.outputSize(aspectRatio: project.stageAspectRatio)
        let bundle = videoURL.deletingLastPathComponent()
        // Export frames wait until face data covers them ("tracking face").
        try await completeFaceTracking(project: project, bundle: bundle)
        try await completeHoverDetection(project: project, bundle: bundle)
        // And for the microphone's silences when the camera hides during them.
        try await SilenceAnalyzer.ensure(project: project, bundle: bundle, recording: videoURL)

        // Hide sensitive data / Hide faces: frames are drawn as the scan reaches them.
        let sensitiveData = streamingSensitiveData(project: project, bundle: bundle, video: bundle.appendingPathComponent(project.recording.videoFileName),
                                                   requesterId: "export-" + UUID().uuidString, options: sensitiveDataOptions)
        if let sensitiveData { observeSensitiveData?(sensitiveData) }
        defer { sensitiveData?.stop() }
        let files = try await withTaskCancellationHandler {
            let state = renderState(project: project, cursors: cursors, bundle: bundle, settings: settings, exportSensitiveData: sensitiveData)
            if let files = try await write(project: project, videoURL: videoURL, settings: settings, outputURL: outputURL, outputSize: outputSize, state: state, readsAhead: readsAhead,
                                           isStale: { await sensitiveData?.isStale() ?? false }, progress: progress) {
                if let result = await sensitiveData?.completeResult() { storeSensitiveDataResult(result, project: project, bundle: bundle) }
                return files
            }
            // Drawn from partial results the complete scan changed: rendered again from it.
            log.warning("The export was rendered with outdated sensitive data covers, rendering it again")
            if let result = await sensitiveData?.completeResult() { storeSensitiveDataResult(result, project: project, bundle: bundle) }
            sensitiveData?.stop()
            let complete = renderState(project: project, cursors: cursors, bundle: bundle, settings: settings)
            guard let files = try await write(project: project, videoURL: videoURL, settings: settings, outputURL: outputURL, outputSize: outputSize, state: complete,
                                              readsAhead: readsAhead, isStale: { false }, progress: progress) else { throw ExportError.cancelled }
            return files
        } onCancel: {
            sensitiveData?.stop()
        }
        return files
    }

    /// Writes the format's files; nil (nothing kept in place) when `isStale` says, once every
    /// frame is written, that the frames must be drawn again.
    private static func write(project: Project, videoURL: URL, settings: ExportSettings, outputURL: URL, outputSize: Size2, state: RenderState, readsAhead: Bool,
                              isStale: @escaping @Sendable () async -> Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL]? {
        switch settings.format {
        case .gif:
            guard try await writeGIF(project: project, videoURL: videoURL, settings: settings, outputSize: outputSize, state: state, to: outputURL, isStale: isStale, progress: progress) else { return nil }
            return [outputURL]
        case .prores:
            guard try await writeMovies(project: project, videoURL: videoURL, settings: settings, outputs: [(nil, outputURL)], outputSize: outputSize, state: state, readsAhead: readsAhead, isStale: isStale, progress: progress) else { return nil }
            return [outputURL]
        case .mp4:
            switch settings.codec {
            case .h264, .h265:
                guard try await writeMovies(project: project, videoURL: videoURL, settings: settings, outputs: [(settings.codec, outputURL)], outputSize: outputSize, state: state, readsAhead: readsAhead, isStale: isStale, progress: progress) else { return nil }
                return [outputURL]
            case .both:
                let hevcURL = outputURL.deletingPathExtension()
                    .appendingPathExtension("hevc")
                    .appendingPathExtension(outputURL.pathExtension)
                // One render feeds both encoders.
                guard try await writeMovies(project: project, videoURL: videoURL, settings: settings, outputs: [(.h264, outputURL), (.h265, hevcURL)], outputSize: outputSize, state: state, readsAhead: readsAhead, isStale: isStale, progress: progress) else { return nil }
                return [outputURL, hevcURL]
            }
        }
    }

    /// What draws the export's frames. Every format is drawn at its output size, so blur,
    /// edges and text land on the pixels that are written.
    /// Cutout frames wait for their stored mattes, so the export is the same whatever the cache held.
    static func renderState(project: Project, cursors: CursorLibrary?, bundle: URL, settings: ExportSettings, exportSensitiveData: ExportSensitiveData? = nil) -> RenderState {
        RenderState(project: project, cursors: cursors, assetsDirectory: bundle, fps: Double(settings.fps), outputSize: settings.outputSize(aspectRatio: project.stageAspectRatio), waitsForStoredMattes: true,
                    exportSensitiveData: exportSensitiveData)
    }

    // MARK: Movie (MP4 / ProRes)

    /// Frames rendered ahead of the encoders: the next one is drawn while the encoders take the
    /// last.
    static let framesAhead = 1

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

    /// Renders the project once and writes every frame into each output, each file with its own
    /// codec. The progress is the share of the movie the slowest output has been given.
    private static func writeMovies(
        project: Project,
        videoURL: URL,
        settings: ExportSettings,
        outputs: [(codec: ExportCodec?, url: URL)],
        outputSize: Size2,
        state: RenderState,
        readsAhead: Bool,
        isStale: @escaping @Sendable () async -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Bool {
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

        var writers: [(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?)] = []
        // MP4s are written beside their outputs and moved there once every output has finished.
        let files = outputs.map { settings.format == .mp4 ? encodingURL(for: $0.url) : $0.url }
        for (output, file) in zip(outputs, files) {
            try? FileManager.default.removeItem(at: file)
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: file, fileType: settings.format == .prores ? .mov : .mp4)
            } catch {
                throw ExportError.cannotWrite(error.localizedDescription)
            }
            // The index goes first, so the movie plays while it downloads.
            writer.shouldOptimizeForNetworkUse = true
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(settings: settings, codec: output.codec, size: outputSize))
            videoInput.expectsMediaDataInRealTime = false
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if audioOutput != nil {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings(format: settings.format))
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioInput = input
            }
            writers.append((writer, videoInput, audioInput))
        }

        nonisolated(unsafe) let startedReader = reader
        nonisolated(unsafe) let startedWriters = writers.map(\.writer)
        try await BlockingWork.run("export start") { _ in
            guard startedReader.startReading() else { throw ExportError.cannotRead(startedReader.error?.localizedDescription ?? "unknown error") }
            for writer in startedWriters {
                guard writer.startWriting() else { throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown error") }
                writer.startSession(atSourceTime: .zero)
            }
        }

        let totalSeconds = max(duration.seconds, 0.001)
        let cancelled = CancellationFlag()
        let given = ExportOutputProgress(outputs: writers.count) { progress(min($0 / totalSeconds, 0.999)) }
        // AVFoundation's reader objects are only read from inside the fan-outs.
        nonisolated(unsafe) let sharedReader = reader
        nonisolated(unsafe) let sharedVideoOutput: AVAssetReaderOutput = videoOutput
        let limiter = FrameRateLimiter(fps: settings.fps)
        let frames = ExportSampleFanOut(consumers: writers.count, maxHeld: framesAhead, readAhead: readsAhead, label: "export frames") {
            while !cancelled.isSet, sharedReader.status == .reading, let buffer = sharedVideoOutput.copyNextSampleBuffer() {
                if limiter.keep(CMSampleBufferGetPresentationTimeStamp(buffer).seconds) { return buffer }
            }
            return nil
        }
        var sounds: ExportSampleFanOut?
        if let audioOutput {
            nonisolated(unsafe) let sharedAudioOutput: AVAssetReaderOutput = audioOutput
            sounds = ExportSampleFanOut(consumers: writers.count) {
                guard !cancelled.isSet, sharedReader.status == .reading else { return nil }
                return sharedAudioOutput.copyNextSampleBuffer()
            }
        }

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (index, writer) in writers.enumerated() {
                    nonisolated(unsafe) let videoInput = writer.video
                    group.addTask {
                        await pump(input: videoInput, samples: frames, consumer: index, label: "video") { buffer in
                            given.record(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, output: index)
                        }
                    }
                    if let audioInput = writer.audio, let sounds {
                        nonisolated(unsafe) let audioInput = audioInput
                        group.addTask {
                            await pump(input: audioInput, samples: sounds, consumer: index, label: "audio") { _ in }
                        }
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }

        if cancelled.isSet || Task.isCancelled {
            reader.cancelReading()
            for (writer, file) in zip(writers, files) {
                writer.writer.cancelWriting()
                try? FileManager.default.removeItem(at: file)
            }
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            for (writer, file) in zip(writers, files) {
                writer.writer.cancelWriting()
                if settings.format == .mp4 { try? FileManager.default.removeItem(at: file) }
            }
            throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        for writer in writers {
            await writer.writer.finishWriting()
        }
        if let failed = writers.first(where: { $0.writer.status != .completed }) {
            if settings.format == .mp4 { for file in files { try? FileManager.default.removeItem(at: file) } }
            throw ExportError.cannotWrite(failed.writer.error?.localizedDescription ?? "unknown error")
        }
        if await isStale() {
            if settings.format == .mp4 { for file in files { try? FileManager.default.removeItem(at: file) } }
            return false
        }
        if settings.format == .mp4 {
            do {
                for (file, output) in zip(files, outputs) {
                    if FileManager.default.fileExists(atPath: output.url.path) {
                        _ = try FileManager.default.replaceItemAt(output.url, withItemAt: file)
                    } else {
                        try FileManager.default.moveItem(at: file, to: output.url)
                    }
                }
            } catch {
                for file in files { try? FileManager.default.removeItem(at: file) }
                throw ExportError.cannotWrite(error.localizedDescription)
            }
        }
        progress(1)
        return true
    }

    /// Where an MP4 is written until the export finishes: a hidden file beside it,
    /// `.<name>.encoding.mp4`.
    static func encodingURL(for output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).encoding.mp4")
    }

    /// Feeds one input its samples until they end, the input refuses one, or the export stops.
    private static func pump(
        input: AVAssetWriterInput,
        samples: ExportSampleFanOut,
        consumer: Int,
        label: String,
        appended: @escaping @Sendable (CMSampleBuffer) -> Void
    ) async {
        let queue = DispatchQueue(label: "regrava.export.\(label).\(consumer)")
        let once = CancellationFlag()
        // The writer input is used only on `queue` here.
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = samples.next(for: consumer), input.append(buffer) else {
                        samples.leave(consumer)
                        input.markAsFinished()
                        if once.setIfUnset() { continuation.resume() }
                        return
                    }
                    appended(buffer)
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
        isStale: @escaping @Sendable () async -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Bool {
        let asset = try await PlaybackComposition.media(asset: AVURLAsset(url: videoURL), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: videoURL.deletingLastPathComponent())).asset
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.cannotRead("no video track") }

        // Composed at the GIF frame rate, one frame every 1/fps from 0.
        let fps = max(settings.fps, 1)
        let kept = (0..<Int((duration * Double(fps)).rounded(.up))).map { Double($0) / Double(fps) }.filter { $0 < duration - 0.0005 }
        guard !kept.isEmpty else { throw ExportError.cannotRead("no frames") }

        let composition = try await CompositionFactory.make(
            asset: asset, state: state, canvas: project.canvasSize, outputSize: outputSize, fps: fps
        )
        let width = Int(outputSize.width), height = Int(outputSize.height)
        let gifSettings = GifEncodingSettings.forMode(settings.quality.gifMode)
        let partialURL = outputURL.appendingPathExtension("partial")

        // The palette comes from sample frames first, then every frame is encoded.
        let steps = Double(max(kept.count * 2, 1))
        try await BlockingWork.run("gif export") { cancellation in
            /// Hands each frame, in order, to `body` with its index while its pixels are locked.
            func readFrames(_ body: (Int, GifFramePixels) throws -> Void) throws {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
                output.videoComposition = composition
                reader.add(output)
                guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error") }
                defer { reader.cancelReading() }
                var next = 0
                while next < kept.count, let buffer = output.copyNextSampleBuffer() {
                    if cancellation.isCancelled { throw ExportError.cancelled }
                    let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    guard abs(time - kept[next]) < 0.0005, let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { continue }
                    let frameWidth = CVPixelBufferGetWidth(pixelBuffer), frameHeight = CVPixelBufferGetHeight(pixelBuffer)
                    guard frameWidth == width, frameHeight == height else {
                        throw ExportError.cannotWrite("A frame does not fit the GIF: \(frameWidth)×\(frameHeight) for a \(width)×\(height) GIF")
                    }
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { continue }
                    let pixels = GifFramePixels(
                        base: base.assumingMemoryBound(to: UInt8.self), width: frameWidth, height: frameHeight,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), layout: .bgra
                    )
                    try body(next, pixels)
                    next += 1
                }
                if reader.status == .failed { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown error") }
            }

            do {
                let sampler = GifPaletteSampler(pixelStride: 2)
                try readFrames { index, pixels in
                    sampler.add(pixels)
                    progress(min(Double(index + 1) / steps, 0.999))
                }
                let palette = sampler.makePalette(maxColors: gifSettings.maxColors)

                try? FileManager.default.removeItem(at: partialURL)
                guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                    throw ExportError.cannotWrite("could not create \(partialURL.path)")
                }
                let handle = try FileHandle(forWritingTo: partialURL)
                defer { try? handle.close() }
                let encoder = GifStreamEncoder(
                    width: width, height: height, framesPerSecond: Double(fps), palette: palette,
                    settings: gifSettings, loops: !settings.gifDisableLoop, output: handle
                )
                try readFrames { index, pixels in
                    try encoder.add(pixels, frameIndex: index)
                    progress(min(Double(kept.count + index + 1) / steps, 0.999))
                }
                _ = try encoder.finish(endFrameIndex: kept.count)
                try handle.synchronize()
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
        }
        if await isStale() {
            try? FileManager.default.removeItem(at: partialURL)
            return false
        }
        try? FileManager.default.removeItem(at: outputURL)
        guard rename(partialURL.path, outputURL.path) == 0 else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ExportError.cannotWrite("could not move the GIF to \(outputURL.path)")
        }
        progress(1)
        return true
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

/// The time of the last frame each output has been given; the export is as far as the slowest.
final class ExportOutputProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double?]
    private let report: @Sendable (Double) -> Void

    /// `report` gets the slowest output's time, in order, once every output has been given a frame.
    init(outputs: Int, report: @escaping @Sendable (Double) -> Void) {
        times = Array(repeating: nil, count: outputs)
        self.report = report
    }

    func record(_ time: Double, output: Int) {
        lock.lock()
        defer { lock.unlock() }
        times[output] = time
        var slowest = Double.infinity
        for time in times {
            guard let time else { return }
            slowest = min(slowest, time)
        }
        report(slowest)
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
