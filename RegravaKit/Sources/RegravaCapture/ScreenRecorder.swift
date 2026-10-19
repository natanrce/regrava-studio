import AVFoundation
import AppKit
import RegravaCore
@preconcurrency import ScreenCaptureKit

/// What to record.
public enum CaptureSource: Hashable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// `rect` is in points, relative to the display's top-left corner.
    case area(displayID: CGDirectDisplayID, rect: CGRect)
}

public struct CaptureOptions: Hashable, Sendable {
    public var fps: Int
    public var capturesSystemAudio: Bool
    /// `AVCaptureDevice.uniqueID` of the microphone, or nil for none.
    public var microphoneID: String?
    public var hidesDesktopIcons: Bool

    /// `AVCaptureDevice.uniqueID` of the camera, or nil for none.
    public var cameraID: String?
    /// "Max resolution" of the camera (`maximumWebcamHeight`).
    public var cameraMaxHeight: Int = 1080

    public init(fps: Int = 60, capturesSystemAudio: Bool = false, microphoneID: String? = nil, hidesDesktopIcons: Bool = false, cameraID: String? = nil, cameraMaxHeight: Int = 1080) {
        self.cameraID = cameraID
        self.cameraMaxHeight = cameraMaxHeight
        self.fps = fps
        self.capturesSystemAudio = capturesSystemAudio
        self.microphoneID = microphoneID
        self.hidesDesktopIcons = hidesDesktopIcons
    }
}

public struct CaptureResult: Sendable {
    public var videoURL: URL
    public var mouseEvents: [MouseEvent]
    /// Images of non-standard cursors referenced by `MouseEvent.cursorID` ("custom-N").
    public var customCursors: [CapturedCursorImage]
    public var keystrokes: [Keystroke]
    /// Source of each audio track, in track order.
    public var audioSources: [AudioSource]
    /// Webcam movie on the same timeline as the screen, if a camera was recorded.
    public var cameraURL: URL?
    public var cameraSize: Size2?
    public var markersMs: [Double]
    public var videoSize: Size2
    public var pointPixelScale: Double
    public var durationMs: Double
    public var fps: Int
}

public enum CaptureError: LocalizedError {
    case sourceNotFound
    case notRecording
    case busy
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound: return "The selected display or window is no longer available."
        case .notRecording: return "No recording is in progress."
        case .busy: return "The recorder is busy."
        case .failed(let message): return message
        }
    }
}

/// Records a display, window or area with ScreenCaptureKit. The system cursor is hidden so it
/// can be redrawn at render time; mouse activity is tracked separately.
///
/// Pausing finalizes the current file segment; resuming starts a new one. Finishing joins the
/// segments into one movie and maps mouse events onto the joined timeline (paused time removed).
@MainActor
public final class ScreenRecorder: NSObject {
    public enum Phase: Equatable, Sendable {
        case idle, starting, recording, pausing, paused, resuming, finishing
    }

    private struct Segment {
        var url: URL
        var startUptime: TimeInterval
        var endUptime: TimeInterval?
    }

    public private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    public var onPhaseChange: ((Phase) -> Void)?
    /// Called when the stream stops on its own (display disconnected, permission revoked…).
    public var onUnexpectedStop: ((Error) -> Void)?

    private var stream: SCStream?
    private var currentOutput: SCRecordingOutput?
    private let mouse = MouseTracker()
    private var camera: CameraRecorder?
    private var expectedAudioSources: [AudioSource] = []
    private let frameSink = FrameSink()
    private var segments: [Segment] = []
    private var markerUptimes: [TimeInterval] = []
    private var workDirectory: URL?
    private var originInPoints: CGPoint = .zero
    private var pointPixelScale: Double = 1
    private var videoSize = Size2(width: 0, height: 0)
    private var fps = 60

    private var startWaiters: [ObjectIdentifier: CheckedContinuation<TimeInterval, Error>] = [:]
    private var finishWaiters: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    public override init() {
        super.init()
    }

    /// Recorded time so far, excluding pauses.
    public var elapsed: TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        return segments.reduce(0) { $0 + (($1.endUptime ?? now) - $1.startUptime) }
    }

    // MARK: Lifecycle

    public func start(source: CaptureSource, options: CaptureOptions, workDirectory: URL) async throws {
        guard phase == .idle else { throw CaptureError.busy }
        phase = .starting
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            self.workDirectory = workDirectory
            segments = []
            markerUptimes = []
            fps = options.fps
            // ScreenCaptureKit writes system audio before the microphone (separate tracks).
            expectedAudioSources = (options.capturesSystemAudio ? [AudioSource.systemAudio] : []) + (options.microphoneID != nil ? [.microphone] : [])

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let (filter, configuration) = try makeFilter(source: source, options: options, content: content)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)
            self.stream = stream

            mouse.start()
            if let cameraID = options.cameraID {
                let camera = CameraRecorder(url: workDirectory.appendingPathComponent("camera-raw.mov"))
                try camera.start(deviceID: cameraID, maxHeight: options.cameraMaxHeight)
                self.camera = camera
            }
            try await stream.startCapture()
            try await beginSegment()
            phase = .recording
        } catch {
            mouse.stop()
            _ = await camera?.stop()
            camera = nil
            try? await stream?.stopCapture()
            stream = nil
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

    /// "Add recording marker" (flag).
    public func addMarker() {
        guard phase == .recording else { return }
        markerUptimes.append(ProcessInfo.processInfo.systemUptime)
    }

    /// Stops recording and writes the joined movie to `outputURL`.
    public func finish(to outputURL: URL) async throws -> CaptureResult {
        guard phase == .recording || phase == .paused else { throw CaptureError.notRecording }
        phase = .finishing
        defer { phase = .idle }
        if currentOutput != nil { try await endSegment() }
        let samples = mouse.stop()
        let cameraRecording = await camera?.stop()
        camera = nil
        try? await stream?.stopCapture()
        stream = nil

        // Real file durations define the joined timeline.
        var offsets: [(segment: Segment, offset: Double, duration: Double)] = []
        var total = 0.0
        for segment in segments {
            let duration = try await AVURLAsset(url: segment.url).load(.duration).seconds
            offsets.append((segment, total, duration))
            total += duration
        }
        try await Self.concatenate(segments.map(\.url), to: outputURL)
        segments.forEach { try? FileManager.default.removeItem(at: $0.url) }

        func timelineMs(_ uptime: TimeInterval) -> Double? {
            for entry in offsets {
                let local = uptime - entry.segment.startUptime
                if local >= 0 && local <= entry.duration + 0.05 {
                    return (entry.offset + min(local, entry.duration)) * 1000
                }
            }
            return nil
        }

        let events = samples.compactMap { sample -> MouseEvent? in
            guard let t = timelineMs(sample.uptime) else { return nil }
            return MouseEvent(
                kind: sample.kind,
                timeMs: t,
                position: Vec2(
                    (sample.location.x - originInPoints.x) * pointPixelScale,
                    (sample.location.y - originInPoints.y) * pointPixelScale
                ),
                button: sample.button,
                cursorID: sample.cursorID
            )
        }
        // Camera movie cut to the same segments, so it lines up with the joined screen movie.
        var cameraURL: URL?
        if let cameraRecording {
            let target = outputURL.deletingLastPathComponent().appendingPathComponent("camera.mov")
            let ranges = offsets.map { (sourceStart: $0.segment.startUptime - cameraRecording.startUptime, duration: $0.duration, at: $0.offset) }
            if (try? await Self.cut(cameraRecording.url, ranges: ranges, to: target)) != nil { cameraURL = target }
            try? FileManager.default.removeItem(at: cameraRecording.url)
        }
        let audioTrackCount = (try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio).count) ?? 0
        let audioSources = Array(expectedAudioSources.prefix(audioTrackCount))
        return CaptureResult(
            videoURL: outputURL,
            mouseEvents: events.sorted { $0.timeMs < $1.timeMs },
            customCursors: mouse.customCursors,
            keystrokes: mouse.keySamples.compactMap { sample in
                timelineMs(sample.uptime).map { Keystroke(kind: sample.kind, timeMs: $0) }
            }.sorted { $0.timeMs < $1.timeMs },
            audioSources: audioSources,
            cameraURL: cameraURL,
            cameraSize: cameraRecording.map { Size2(width: Double($0.size.width), height: Double($0.size.height)) },
            markersMs: markerUptimes.compactMap(timelineMs),
            videoSize: videoSize,
            pointPixelScale: pointPixelScale,
            durationMs: total * 1000,
            fps: fps
        )
    }

    /// Stops and deletes everything recorded so far.
    public func cancel() async {
        if let output = currentOutput { try? stream?.removeRecordingOutput(output) }
        currentOutput = nil
        mouse.stop()
        if let recording = await camera?.stop() { try? FileManager.default.removeItem(at: recording.url) }
        camera = nil
        try? await stream?.stopCapture()
        stream = nil
        segments.forEach { try? FileManager.default.removeItem(at: $0.url) }
        segments = []
        phase = .idle
    }

    // MARK: Segments

    private func beginSegment() async throws {
        guard let stream, let workDirectory else { throw CaptureError.notRecording }
        let url = workDirectory.appendingPathComponent("segment-\(segments.count).mov")
        try? FileManager.default.removeItem(at: url)
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mov
        configuration.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: configuration, delegate: self)
        let key = ObjectIdentifier(output)
        currentOutput = output
        try stream.addRecordingOutput(output)
        let startUptime = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimeInterval, Error>) in
            startWaiters[key] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.resolveStart(key, .failure(CaptureError.failed("The recording did not start. Check the Screen Recording permission.")))
            }
        }
        segments.append(Segment(url: url, startUptime: startUptime))
    }

    private func endSegment() async throws {
        guard let stream, let output = currentOutput else { return }
        let key = ObjectIdentifier(output)
        let endUptime = ProcessInfo.processInfo.systemUptime
        currentOutput = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishWaiters[key] = continuation
            do {
                try stream.removeRecordingOutput(output)
            } catch {
                resolveFinish(key, error)
                return
            }
            Task { @MainActor in
                // Safety net in case the finish callback never arrives.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.resolveFinish(key, nil)
            }
        }
        if !segments.isEmpty { segments[segments.count - 1].endUptime = endUptime }
    }

    private func resolveStart(_ key: ObjectIdentifier, _ result: Result<TimeInterval, Error>) {
        guard let continuation = startWaiters.removeValue(forKey: key) else { return }
        continuation.resume(with: result)
    }

    private func resolveFinish(_ key: ObjectIdentifier, _ error: Error?) {
        guard let continuation = finishWaiters.removeValue(forKey: key) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    // MARK: Filter

    private func makeFilter(source: CaptureSource, options: CaptureOptions, content: SCShareableContent) throws -> (SCContentFilter, SCStreamConfiguration) {
        let pid = ProcessInfo.processInfo.processIdentifier
        var excluded = content.windows.filter { $0.owningApplication?.processID == pid }
        if options.hidesDesktopIcons {
            excluded += content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer < 0
            }
        }

        let filter: SCContentFilter
        var sourceRect: CGRect?
        let sizeInPoints: CGSize
        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            originInPoints = CGDisplayBounds(id).origin
            sizeInPoints = CGSize(width: display.width, height: display.height)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceNotFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
            originInPoints = window.frame.origin
            sizeInPoints = window.frame.size
        case let .area(id, rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            let origin = CGDisplayBounds(id).origin
            originInPoints = CGPoint(x: origin.x + rect.minX, y: origin.y + rect.minY)
            sourceRect = rect
            sizeInPoints = rect.size
        }

        pointPixelScale = Double(filter.pointPixelScale)
        let width = Int((Double(sizeInPoints.width) * pointPixelScale).rounded())
        let height = Int((Double(sizeInPoints.height) * pointPixelScale).rounded())
        videoSize = Size2(width: Double(width), height: Double(height))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 6
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if let microphoneID = options.microphoneID {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = microphoneID
        }
        return (filter, configuration)
    }

    // MARK: Joining

    /// Copies ranges of a movie (seconds) to new positions on a new timeline.
    static func cut(_ url: URL, ranges: [(sourceStart: Double, duration: Double, at: Double)], to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        let composition = AVMutableComposition()
        for range in ranges {
            let start = max(range.sourceStart, 0)
            let end = min(range.sourceStart + range.duration, total)
            guard end > start else { continue }
            try await composition.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600)),
                of: asset,
                at: CMTime(seconds: range.at + (start - range.sourceStart), preferredTimescale: 600)
            )
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.failed("Could not save the camera recording.")
        }
        try await session.export(to: outputURL, as: .mov)
    }

    static func concatenate(_ urls: [URL], to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard urls.count > 1 else {
            guard let only = urls.first else { throw CaptureError.failed("Nothing was recorded.") }
            try FileManager.default.moveItem(at: only, to: outputURL)
            return
        }
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            cursor = cursor + duration
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.failed("Could not join the recording segments.")
        }
        try await session.export(to: outputURL, as: .mov)
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            for key in Array(self.startWaiters.keys) { self.resolveStart(key, .failure(error)) }
            for key in Array(self.finishWaiters.keys) { self.resolveFinish(key, error) }
            if self.phase == .recording || self.phase == .paused { self.onUnexpectedStop?(error) }
        }
    }

    nonisolated public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let key = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.resolveStart(key, .success(uptime)) }
    }

    nonisolated public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let key = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.resolveFinish(key, nil) }
    }

    nonisolated public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let key = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            self.resolveStart(key, .failure(error))
            self.resolveFinish(key, error)
        }
    }
}

/// Screen frames need a consumer for the stream to run; files are written by `SCRecordingOutput`.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "regrava.capture.frames", qos: .userInitiated)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
