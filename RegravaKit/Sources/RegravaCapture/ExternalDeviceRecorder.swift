@preconcurrency import AVFoundation
import AppKit
import CoreImage
import RegravaCore
@preconcurrency import ScreenCaptureKit

/// Records an iPhone or iPad connected by cable: the device's screen and audio from one
/// capture session, plus the Mac microphone, system audio and webcam when chosen. The device's
/// audio plays through the Mac's speakers while recording.
///
/// Like `ScreenRecorder`, pausing closes a file segment and resuming opens a new one; finishing
/// joins them. Frames that arrive rotated (the device turned) are rotated back to the first
/// frame's size and each turn is logged.
@MainActor
public final class ExternalDeviceRecorder {
    public typealias Phase = ScreenRecorder.Phase

    public private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    public var onPhaseChange: ((Phase) -> Void)?
    public var onUnexpectedStop: ((Error) -> Void)?

    private struct Segment {
        var url: URL
        var startUptime: TimeInterval
        var endUptime: TimeInterval?
    }

    private var core: DeviceCaptureCore?
    private var camera: CameraRecorder?
    private var segments: [Segment] = []
    private var markerUptimes: [TimeInterval] = []
    private var workDirectory: URL?
    private var device: ExternalDevice?

    public init() {}

    public var elapsed: TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        return segments.reduce(0) { $0 + (($1.endUptime ?? now) - $1.startUptime) }
    }

    nonisolated public static let noFramesMessage = "Cannot record your device. Make sure to unlock your device, and try again."

    public func start(device: ExternalDevice, options: CaptureOptions, workDirectory: URL) async throws {
        guard phase == .idle else { throw CaptureError.busy }
        phase = .starting
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            self.workDirectory = workDirectory
            self.device = device
            segments = []
            markerUptimes = []
            guard let captureDevice = AVCaptureDevice(uniqueID: device.deviceId) else {
                throw CaptureError.failed("Failed to find or connect to selected device")
            }
            let core = DeviceCaptureCore()
            core.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.phase == .recording || self.phase == .paused else { return }
                    self.onUnexpectedStop?(error)
                }
            }
            try core.configure(device: captureDevice, microphoneID: options.microphoneID)
            if options.capturesSystemAudio { try await core.startSystemAudio(processIDs: options.systemAudioProcessIDs) }
            self.core = core
            if let cameraID = options.cameraID {
                let camera = CameraRecorder(url: workDirectory.appendingPathComponent("camera-raw.mov"))
                try camera.start(deviceID: cameraID, maxHeight: options.cameraMaxHeight)
                self.camera = camera
            }
            core.startRunning()
            try await beginSegment()
            phase = .recording
        } catch {
            await core?.stopRunning()
            core = nil
            _ = await camera?.stop()
            camera = nil
            phase = .idle
            throw error
        }
    }

    public func pause() async throws {
        guard phase == .recording else { throw CaptureError.notRecording }
        phase = .pausing
        try await endSegment()
        phase = .paused
    }

    public func resume() async throws {
        guard phase == .paused else { throw CaptureError.notRecording }
        phase = .resuming
        try await beginSegment()
        phase = .recording
    }

    public func addMarker() {
        guard phase == .recording else { return }
        markerUptimes.append(ProcessInfo.processInfo.systemUptime)
    }

    private func beginSegment() async throws {
        guard let core, let workDirectory else { throw CaptureError.notRecording }
        let url = workDirectory.appendingPathComponent("segment-\(segments.count).mov")
        try? FileManager.default.removeItem(at: url)
        let start = try await core.beginSegment(url: url, timeout: 5)
        segments.append(Segment(url: url, startUptime: start))
    }

    private func endSegment() async throws {
        guard let core else { return }
        let end = try await core.endSegment()
        if !segments.isEmpty { segments[segments.count - 1].endUptime = end ?? ProcessInfo.processInfo.systemUptime }
    }

    /// Stops and writes the joined movie to `outputURL`.
    public func finish(to outputURL: URL) async throws -> CaptureResult {
        guard phase == .recording || phase == .paused, let core else { throw CaptureError.notRecording }
        let wasPaused = phase == .paused
        phase = .finishing
        defer { phase = .idle }
        if !wasPaused { try await endSegment() }
        await core.stopRunning()
        let cameraRecording = await camera?.stop()
        camera = nil
        self.core = nil

        var offsets: [(segment: Segment, offset: Double, duration: Double)] = []
        var total = 0.0
        for segment in segments {
            let duration = try await AVURLAsset(url: segment.url).load(.duration).seconds
            offsets.append((segment, total, duration))
            total += duration
        }
        try await ScreenRecorder.concatenate(segments.map(\.url), to: outputURL)
        segments.forEach { try? FileManager.default.removeItem(at: $0.url) }

        func timelineMs(_ uptime: TimeInterval) -> Double? {
            for entry in offsets {
                let local = uptime - entry.segment.startUptime
                if local >= 0 && local <= entry.duration + 0.05 { return (entry.offset + min(local, entry.duration)) * 1000 }
            }
            return nil
        }

        var cameraURL: URL?
        if let cameraRecording {
            let target = outputURL.deletingLastPathComponent().appendingPathComponent("camera.mov")
            let ranges = offsets.map { (sourceStart: $0.segment.startUptime - cameraRecording.startUptime, duration: $0.duration, at: $0.offset) }
            if (try? await ScreenRecorder.cut(cameraRecording.url, ranges: ranges, to: target)) != nil { cameraURL = target }
            try? FileManager.default.removeItem(at: cameraRecording.url)
        }
        let size = core.initialSize
        let changes = core.orientationChanges.compactMap { change -> DeviceOrientationChange? in
            timelineMs(change.uptime).map { DeviceOrientationChange(timeMs: $0, contentRect: change.contentRect, videoRotationAngleForHorizontalLevel: change.angle, animation: change.animation) }
        }
        var result = CaptureResult(
            videoURL: outputURL,
            mouseEvents: [],
            customCursors: [],
            keystrokes: [],
            audioSources: core.audioSources,
            cameraURL: cameraURL,
            cameraSize: cameraRecording.map { Size2(width: Double($0.size.width), height: Double($0.size.height)) },
            markersMs: markerUptimes.compactMap(timelineMs),
            videoSize: Size2(width: Double(size.width), height: Double(size.height)),
            pointPixelScale: 1,
            durationMs: total * 1000,
            fps: 60
        )
        if let device {
            result.externalDevice = ExternalDeviceInfo(deviceId: device.deviceId, name: device.name, modelId: device.modelId, modelMarketingName: device.modelMarketingName, orientationChanges: changes)
        }
        return result
    }

    public func cancel() async {
        _ = try? await core?.endSegment()
        await core?.stopRunning()
        core = nil
        if let recording = await camera?.stop() { try? FileManager.default.removeItem(at: recording.url) }
        camera = nil
        segments.forEach { try? FileManager.default.removeItem(at: $0.url) }
        segments = []
        phase = .idle
    }
}

/// The capture sessions and the segment writer, confined to one serial queue.
final class DeviceCaptureCore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, @unchecked Sendable {
    struct OrientationChange {
        var uptime: TimeInterval
        var contentRect: Rect2
        var angle: Double
        var animation: DeviceOrientationChange.Animation
    }

    let queue = DispatchQueue(label: "regrava.device.capture", qos: .userInitiated)
    private let deviceSession = AVCaptureSession()
    private let microphoneSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let deviceAudioOutput = AVCaptureAudioDataOutput()
    private let microphoneOutput = AVCaptureAudioDataOutput()
    private var systemAudioStream: SCStream?
    private let frameSink = FrameSink()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var isMonitoring = false
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var hasMicrophone = false
    private var hasSystemAudio = false

    var onFailure: ((Error) -> Void)?

    // Queue state.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInputs: [AudioSource: AVAssetWriterInput] = [:]
    private var pendingSegment: (url: URL, continuation: CheckedContinuation<TimeInterval, Error>)?
    private var segmentStart: CMTime?
    private var lastVideoTime: CMTime?
    private var isRotated = false
    private var pool: CVPixelBufferPool?
    private(set) var initialSize = CGSize.zero
    private(set) var orientationChanges: [OrientationChange] = []

    /// Track order of the written audio.
    var audioSources: [AudioSource] {
        [.externalDevice] + (hasSystemAudio ? [.systemAudio] : []) + (hasMicrophone ? [.microphone] : [])
    }

    func configure(device: AVCaptureDevice, microphoneID: String?) throws {
        let input = try AVCaptureDeviceInput(device: device)
        deviceSession.beginConfiguration()
        guard deviceSession.canAddInput(input) else {
            deviceSession.commitConfiguration()
            throw CaptureError.failed("Failed to find or connect to selected device")
        }
        deviceSession.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if deviceSession.canAddOutput(videoOutput) { deviceSession.addOutput(videoOutput) }
        deviceAudioOutput.setSampleBufferDelegate(self, queue: queue)
        if deviceSession.canAddOutput(deviceAudioOutput) { deviceSession.addOutput(deviceAudioOutput) }
        deviceSession.commitConfiguration()

        if let microphoneID, let microphone = AVCaptureDevice(uniqueID: microphoneID), let micInput = try? AVCaptureDeviceInput(device: microphone) {
            microphoneSession.beginConfiguration()
            if microphoneSession.canAddInput(micInput) { microphoneSession.addInput(micInput) }
            microphoneOutput.setSampleBufferDelegate(self, queue: queue)
            if microphoneSession.canAddOutput(microphoneOutput) { microphoneSession.addOutput(microphoneOutput) }
            microphoneSession.commitConfiguration()
            hasMicrophone = true
        }
        // The device's audio plays through the default speaker.
        synchronizer.addRenderer(audioRenderer)
    }

    /// System audio through ScreenCaptureKit, with a tiny video stream nobody reads.
    /// Every app's sound, or only `processIDs`' (checked like `SystemAudioRecorder`).
    func startSystemAudio(processIDs: [pid_t]? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return }
        var filter = SCContentFilter(display: display, excludingWindows: [])
        if let processIDs {
            guard !processIDs.isEmpty else { throw CaptureError.failed("SystemAudio: includedProcessIds cannot be set to empty array") }
            let apps = content.applications.filter { processIDs.contains($0.processID) }
            guard !apps.isEmpty else { throw CaptureError.failed("SystemAudio: None of the includedProcessIds can be found, cannot record audio ") }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        systemAudioStream = stream
        hasSystemAudio = true
    }

    func startRunning() {
        deviceSession.startRunning()
        if hasMicrophone { microphoneSession.startRunning() }
    }

    func stopRunning() async {
        deviceSession.stopRunning()
        if hasMicrophone { microphoneSession.stopRunning() }
        try? await systemAudioStream?.stopCapture()
        systemAudioStream = nil
        synchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
    }

    /// Opens a segment at the next video frame and returns its uptime. Fails when no frame
    /// arrives in `timeout` seconds (a locked device sends none).
    func beginSegment(url: URL, timeout: TimeInterval) async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pendingSegment = (url, continuation)
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard let pending = self.pendingSegment, pending.url == url else { return }
                self.pendingSegment = nil
                pending.continuation.resume(throwing: CaptureError.failed(ExternalDeviceRecorder.noFramesMessage))
            }
        }
    }

    /// Closes the current segment; returns the uptime of its last frame.
    func endSegment() async throws -> TimeInterval? {
        let (writer, inputs, end): (AVAssetWriter?, [AVAssetWriterInput], CMTime?) = await withCheckedContinuation { continuation in
            queue.async {
                let w = self.writer
                let inputs = [self.videoInput].compactMap { $0 } + Array(self.audioInputs.values)
                let end = self.lastVideoTime
                self.writer = nil
                self.videoInput = nil
                self.audioInputs = [:]
                self.segmentStart = nil
                continuation.resume(returning: (w, inputs, end))
            }
        }
        guard let writer else { return nil }
        inputs.forEach { $0.markAsFinished() }
        if let end { writer.endSession(atSourceTime: end) }
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? CaptureError.failed("Could not save the device recording.") }
        return end?.seconds
    }

    // MARK: Samples (queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === deviceAudioOutput {
            monitor(sampleBuffer)
            append(sampleBuffer, source: .externalDevice)
        } else if output === microphoneOutput {
            append(sampleBuffer, source: .microphone)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        append(sampleBuffer, source: .systemAudio)
    }

    private func monitor(_ sampleBuffer: CMSampleBuffer) {
        if !isMonitoring {
            synchronizer.setRate(1, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            isMonitoring = true
        }
        if audioRenderer.isReadyForMoreMediaData { audioRenderer.enqueue(sampleBuffer) }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        if initialSize == .zero { initialSize = size }

        // The device turned: the frame's sides are swapped against the first frame.
        let rotated = size != initialSize && size.width == initialSize.height && size.height == initialSize.width
        if rotated != isRotated {
            isRotated = rotated
            orientationChanges.append(OrientationChange(
                uptime: time.seconds,
                contentRect: Rect2(x: 0, y: 0, width: Double(initialSize.width), height: Double(initialSize.height)),
                angle: rotated ? 90 : 0,
                animation: rotated ? .clockwise : .counterClockwise
            ))
        }

        if let pending = pendingSegment {
            pendingSegment = nil
            do {
                try openWriter(url: pending.url, at: time)
                pending.continuation.resume(returning: time.seconds)
            } catch {
                pending.continuation.resume(throwing: error)
                return
            }
        }
        guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
        if size == initialSize {
            videoInput.append(sampleBuffer)
        } else if let buffer = rotate(image, to: initialSize), let adaptor = adaptor {
            adaptor.append(buffer, withPresentationTime: time)
        }
        lastVideoTime = time
    }

    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    /// "Created rotated CMSampleBuffer": the frame turned a quarter back to the initial size.
    private func rotate(_ image: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let source = CIImage(cvPixelBuffer: image)
        let turned = source.oriented(.right)
        ciContext.render(turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY)), to: out)
        return out
    }

    private func openWriter(url: URL, at time: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(initialSize.width), height = Int(initialSize.height)
        var settings = AVOutputSettingsAssistant(preset: .preset3840x2160)?.videoSettings ?? [AVVideoCodecKey: AVVideoCodecType.h264]
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        if var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
            compression[AVVideoAverageBitRateKey] = max(width * height * 8, 2_000_000)
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        var inputs: [AudioSource: AVAssetWriterInput] = [:]
        for source in audioSources {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            inputs[source] = audio
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.failed("Could not record the device.") }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = video
        audioInputs = inputs
        segmentStart = time
    }

    private func append(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        guard let start = segmentStart, let input = audioInputs[source], input.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        input.append(sampleBuffer)
    }
}
