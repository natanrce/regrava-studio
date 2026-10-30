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
        var startUptime: TimeInterval
        var endUptime: TimeInterval?
    }

    private var core: DeviceCaptureCore?
    private var camera: CameraRecorder?
    private var segments: [Segment] = []
    private var workDirectory: URL?
    private var journal: RecordingJournal?
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
            let journal = try RecordingJournal(folder: workDirectory)
            self.journal = journal
            self.workDirectory = workDirectory
            self.device = device
            segments = []
            journal.update {
                $0.pointPixelScale = 1
                $0.fps = 60
                $0.device = ExternalDeviceInfo(deviceId: device.deviceId, name: device.name, modelId: device.modelId, modelMarketingName: device.modelMarketingName, orientationChanges: [])
            }
            guard let captureDevice = AVCaptureDevice(uniqueID: device.deviceId) else {
                throw CaptureError.failed("Failed to find or connect to selected device")
            }
            let core = DeviceCaptureCore(directory: workDirectory)
            core.onFirstFrame = { size in
                Task { @MainActor in journal.update { $0.videoSize = Size2(width: Double(size.width), height: Double(size.height)) } }
            }
            core.onOrientationChange = { change in
                Task { @MainActor in
                    journal.update { $0.orientationChanges.append(.init(uptime: change.uptime, contentRect: change.contentRect, angle: change.angle, animation: change.animation)) }
                }
            }
            core.onChannelStart = { index, name, start in
                Task { @MainActor in
                    journal.update { metadata in
                        guard let s = metadata.sessions.firstIndex(where: { $0.index == index }),
                              let c = metadata.sessions[s].channels.firstIndex(where: { $0.playlist == name }) else { return }
                        metadata.sessions[s].channels[c].startUptime = start
                    }
                }
            }
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
                let camera = CameraRecorder(directory: workDirectory)
                camera.onStart = { start, size in
                    Task { @MainActor in
                        journal.update { $0.continuous.append(.init(source: "webcam", playlist: "channel-3-webcam-0", startUptime: start, width: Double(size.width), height: Double(size.height))) }
                    }
                }
                try await camera.start(deviceID: cameraID, maxHeight: options.cameraMaxHeight)
                self.camera = camera
            }
            await core.startRunning()
            try await beginSegment()
            phase = .recording
        } catch {
            await core?.stopRunning()
            core = nil
            await camera?.stop()
            camera = nil
            journal?.close()
            journal = nil
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
        let now = ProcessInfo.processInfo.systemUptime
        journal?.update { $0.markerUptimes.append(now) }
    }

    private func beginSegment() async throws {
        guard let core, let journal else { throw CaptureError.notRecording }
        let index = segments.count
        journal.update { $0.sessions.append(.init(index: index, channels: core.channelNames(index: index).map { .init(source: $0.source, playlist: $0.playlist) })) }
        let start = try await core.beginSegment(index: index, timeout: 5)
        segments.append(Segment(startUptime: start))
        journal.update { metadata in
            if let s = metadata.sessions.firstIndex(where: { $0.index == index }) { metadata.sessions[s].startUptime = start }
        }
    }

    private func endSegment() async throws {
        guard let core else { return }
        let end = try await core.endSegment() ?? ProcessInfo.processInfo.systemUptime
        guard !segments.isEmpty else { return }
        segments[segments.count - 1].endUptime = end
        let index = segments.count - 1
        journal?.update { metadata in
            if let s = metadata.sessions.firstIndex(where: { $0.index == index }) { metadata.sessions[s].endUptime = end }
        }
    }

    /// Stops and finalizes the folder; the movie ends up at `outputURL`.
    public func finish(to outputURL: URL) async throws -> CaptureResult {
        guard phase == .recording || phase == .paused, let core, let workDirectory else { throw CaptureError.notRecording }
        let wasPaused = phase == .paused
        phase = .finishing
        defer { phase = .idle }
        if !wasPaused { try await endSegment() }
        await core.stopRunning()
        await camera?.stop()
        camera = nil
        self.core = nil
        journal?.close()
        journal = nil
        var result = try await RecordingFinalizer.finalize(folder: workDirectory)
        try ScreenRecorder.move(&result, to: outputURL)
        return result
    }

    public func cancel() async {
        _ = try? await core?.endSegment()
        await core?.stopRunning()
        core = nil
        await camera?.stop()
        camera = nil
        journal?.close()
        journal = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        segments = []
        phase = .idle
    }
}

/// The capture sessions and the segment writer, confined to one serial queue.
final class DeviceCaptureCore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct OrientationChange {
        var uptime: TimeInterval
        var contentRect: Rect2
        var angle: Double
        var animation: DeviceOrientationChange.Animation
    }

    let queue = DispatchQueue(label: "regrava.device.capture", qos: .userInitiated)
    /// `startRunning`/`stopRunning` block until the sessions are up or down; they run here.
    private let sessionQueue = DispatchQueue(label: "regrava.device.session", qos: .userInitiated)
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
    var onFirstFrame: (@Sendable (CGSize) -> Void)?
    var onOrientationChange: (@Sendable (OrientationChange) -> Void)?
    /// A session's channel got its first sample: session index, playlist name, host time.
    var onChannelStart: (@Sendable (Int, String, Double) -> Void)?

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    /// The channels a session writes (the device's picture, then each sound).
    func channelNames(index: Int) -> [(source: String, playlist: String)] {
        [("device", "channel-1-device-\(index)")] + audioSources.map { source in
            switch source {
            case .externalDevice: return (source.rawValue, "channel-5-external-device-\(index)")
            case .systemAudio: return (source.rawValue, "channel-4-system-audio-\(index)")
            case .microphone: return (source.rawValue, "channel-2-microphone-\(index)")
            }
        }
    }

    // Queue state.
    private var videoWriter: SegmentedWriter?
    private var audioWriters: [AudioSource: SegmentedWriter] = [:]
    private var pendingSegment: (index: Int, continuation: CheckedContinuation<TimeInterval, Error>)?
    private var segmentStart: CMTime?
    private var lastVideoTime: CMTime?
    private var isRotated = false
    private var pool: CVPixelBufferPool?
    private(set) var initialSize = CGSize.zero

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
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        systemAudioStream = stream
        hasSystemAudio = true
    }

    func startRunning() async {
        await onSessionQueue {
            self.deviceSession.startRunning()
            if self.hasMicrophone { self.microphoneSession.startRunning() }
        }
    }

    func stopRunning() async {
        await onSessionQueue {
            self.deviceSession.stopRunning()
            if self.hasMicrophone { self.microphoneSession.stopRunning() }
        }
        try? await systemAudioStream?.stopCapture()
        systemAudioStream = nil
        synchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
    }

    private func onSessionQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    /// Opens a segment at the next video frame and returns its uptime. Fails when no frame
    /// arrives in `timeout` seconds (a locked device sends none).
    func beginSegment(index: Int, timeout: TimeInterval) async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pendingSegment = (index, continuation)
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard let pending = self.pendingSegment, pending.index == index else { return }
                self.pendingSegment = nil
                pending.continuation.resume(throwing: CaptureError.failed(ExternalDeviceRecorder.noFramesMessage))
            }
        }
    }

    /// Closes the current session's channels; returns the uptime of its last frame.
    func endSegment() async throws -> TimeInterval? {
        let (writers, end): ([SegmentedWriter], CMTime?) = await withCheckedContinuation { continuation in
            queue.async {
                let writers = [self.videoWriter].compactMap { $0 } + Array(self.audioWriters.values)
                let end = self.lastVideoTime
                self.videoWriter = nil
                self.audioWriters = [:]
                self.segmentStart = nil
                continuation.resume(returning: (writers, end))
            }
        }
        guard !writers.isEmpty else { return nil }
        for writer in writers { await writer.finish() }
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

    /// The system audio stream stopped on its own: the recording is aborted.
    /// Optional: the stream may report a stop without an error.
    func stream(_ stream: SCStream, didStopWithError error: Error?) {
        onFailure?(CaptureError.streamStop(error, isLowDiskSpace: CaptureError.isVolumeLowOnDiskSpace(directory)))
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
        if initialSize == .zero {
            initialSize = size
            onFirstFrame?(size)
        }

        // The device turned: the frame's sides are swapped against the first frame.
        let rotated = size != initialSize && size.width == initialSize.height && size.height == initialSize.width
        if rotated != isRotated {
            isRotated = rotated
            let change = OrientationChange(
                uptime: time.seconds,
                contentRect: Rect2(x: 0, y: 0, width: Double(initialSize.width), height: Double(initialSize.height)),
                angle: rotated ? 90 : 0,
                animation: rotated ? .clockwise : .counterClockwise
            )
            onOrientationChange?(change)
        }

        if let pending = pendingSegment {
            pendingSegment = nil
            do {
                try openWriters(index: pending.index, at: time)
                pending.continuation.resume(returning: time.seconds)
            } catch {
                pending.continuation.resume(throwing: error)
                return
            }
        }
        guard let videoWriter else { return }
        if size == initialSize {
            videoWriter.append(sampleBuffer)
        } else if let buffer = rotate(image, to: initialSize) {
            videoWriter.append(buffer, at: time)
        }
        lastVideoTime = time
    }

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

    /// A session's channels: the picture at the first frame's size, and one per sound.
    private func openWriters(index: Int, at time: CMTime) throws {
        let width = Int(initialSize.width), height = Int(initialSize.height)
        var settings = AVOutputSettingsAssistant(preset: .preset3840x2160)?.videoSettings ?? [AVVideoCodecKey: AVVideoCodecType.h264]
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        if var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
            compression[AVVideoAverageBitRateKey] = max(width * height * 8, 2_000_000)
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        let names = channelNames(index: index)
        let video = try SegmentedWriter(directory: directory, name: names[0].playlist, mediaType: .video, outputSettings: settings)
        var audio: [AudioSource: SegmentedWriter] = [:]
        for (source, name) in zip(audioSources, names.dropFirst().map(\.playlist)) {
            audio[source] = try SegmentedWriter(directory: directory, name: name, mediaType: .audio, outputSettings: SegmentedWriter.audioSettings)
        }
        for writer in [video] + Array(audio.values) {
            let name = writer.name
            writer.onStart = { [weak self] start in self?.onChannelStart?(index, name, start) }
        }
        videoWriter = video
        audioWriters = audio
        segmentStart = time
    }

    private func append(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        guard let start = segmentStart, let writer = audioWriters[source],
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        writer.append(sampleBuffer)
    }
}
