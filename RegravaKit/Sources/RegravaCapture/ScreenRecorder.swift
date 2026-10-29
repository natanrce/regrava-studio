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
    /// With `capturesSystemAudio`: only these apps' sound (`only-selected`), recorded in its
    /// own stream; nil records every app.
    public var systemAudioProcessIDs: [pid_t]?
    /// `AVCaptureDevice.uniqueID` of the microphone, or nil for none.
    public var microphoneID: String?
    public var hidesDesktopIcons: Bool

    /// `AVCaptureDevice.uniqueID` of the camera, or nil for none.
    public var cameraID: String?
    /// "Max resolution" of the camera (`maximumWebcamHeight`).
    public var cameraMaxHeight: Int = 1080

    public init(fps: Int = 60, capturesSystemAudio: Bool = false, systemAudioProcessIDs: [pid_t]? = nil, microphoneID: String? = nil, hidesDesktopIcons: Bool = false, cameraID: String? = nil, cameraMaxHeight: Int = 1080) {
        self.systemAudioProcessIDs = systemAudioProcessIDs
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
    /// The iPhone/iPad of a device recording.
    public var externalDevice: ExternalDeviceInfo?
    /// `recordingFlags`: "ScreenContinuity" for iPhone Mirroring windows.
    public var flags: [String] = []
    /// Starts of the sessions after the first, on the joined timeline.
    public var sessionStartsMs: [Double] = []

    public init(videoURL: URL, mouseEvents: [MouseEvent], customCursors: [CapturedCursorImage], keystrokes: [Keystroke], audioSources: [AudioSource],
                cameraURL: URL?, cameraSize: Size2?, markersMs: [Double], videoSize: Size2, pointPixelScale: Double, durationMs: Double, fps: Int,
                externalDevice: ExternalDeviceInfo? = nil, flags: [String] = [], sessionStartsMs: [Double] = []) {
        self.videoURL = videoURL
        self.mouseEvents = mouseEvents
        self.customCursors = customCursors
        self.keystrokes = keystrokes
        self.audioSources = audioSources
        self.cameraURL = cameraURL
        self.cameraSize = cameraSize
        self.markersMs = markersMs
        self.videoSize = videoSize
        self.pointPixelScale = pointPixelScale
        self.durationMs = durationMs
        self.fps = fps
        self.externalDevice = externalDevice
        self.flags = flags
        self.sessionStartsMs = sessionStartsMs
    }
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
/// Everything is written into the recording folder as it records: each session (pauses end one)
/// writes its picture, system audio and microphone as segmented channels, the webcam and the
/// selected apps' sound run as continuous channels, and `metadata-raw.json` plus the event logs
/// keep the rest. Finishing hands the folder to `RecordingFinalizer`, as recovery does.
@MainActor
public final class ScreenRecorder: NSObject {
    public enum Phase: Equatable, Sendable {
        case idle, starting, recording, pausing, paused, resuming, finishing
    }

    private struct Segment {
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
    private let mouse = MouseTracker()
    private var camera: CameraRecorder?
    private var systemAudio: SystemAudioRecorder?
    private let channels = StreamChannels()
    private var segments: [Segment] = []
    private var workDirectory: URL?
    private var journal: RecordingJournal?
    private var options = CaptureOptions()
    private var originInPoints: CGPoint = .zero
    private var pointPixelScale: Double = 1
    private var videoSize = Size2(width: 0, height: 0)
    private var flags: [String] = []
    static let screenContinuityBundleID = "com.apple.ScreenContinuity"
    private var fps = 60

    public override init() {
        super.init()
    }

    /// Recorded time so far, excluding pauses.
    public var elapsed: TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        return segments.reduce(0) { $0 + (($1.endUptime ?? now) - $1.startUptime) }
    }

    // MARK: Lifecycle

    /// Records into `workDirectory` (the recording folder, which `finish` finalizes in place).
    public func start(source: CaptureSource, options: CaptureOptions, workDirectory: URL) async throws {
        guard phase == .idle else { throw CaptureError.busy }
        phase = .starting
        do {
            let journal = try RecordingJournal(folder: workDirectory)
            self.journal = journal
            self.workDirectory = workDirectory
            self.options = options
            segments = []
            fps = options.fps

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let (filter, configuration) = try makeFilter(source: source, options: options, content: content)
            journal.update {
                $0.videoSize = videoSize
                $0.pointPixelScale = pointPixelScale
                $0.originX = originInPoints.x
                $0.originY = originInPoints.y
                $0.fps = fps
                $0.flags = flags
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(channels, type: .screen, sampleHandlerQueue: channels.queue)
            if configuration.capturesAudio { try stream.addStreamOutput(channels, type: .audio, sampleHandlerQueue: channels.queue) }
            if configuration.captureMicrophone { try stream.addStreamOutput(channels, type: .microphone, sampleHandlerQueue: channels.queue) }
            self.stream = stream

            mouse.journal = journal
            mouse.start()
            if let cameraID = options.cameraID {
                let camera = CameraRecorder(directory: workDirectory)
                camera.onStart = { start, size in
                    Task { @MainActor in
                        journal.update { $0.continuous.append(.init(source: "webcam", playlist: "channel-3-webcam-0", startUptime: start, width: Double(size.width), height: Double(size.height))) }
                    }
                }
                try camera.start(deviceID: cameraID, maxHeight: options.cameraMaxHeight)
                self.camera = camera
            }
            if options.capturesSystemAudio, let pids = options.systemAudioProcessIDs {
                let recorder = SystemAudioRecorder(directory: workDirectory)
                recorder.onStart = { start in
                    Task { @MainActor in
                        journal.update { $0.continuous.append(.init(source: AudioSource.systemAudio.rawValue, playlist: "channel-4-system-audio-apps-0", startUptime: start)) }
                    }
                }
                try await recorder.start(processIDs: pids, content: content)
                systemAudio = recorder
            }
            try await stream.startCapture()
            try await beginSegment()
            phase = .recording
        } catch {
            mouse.stop()
            _ = await camera?.stop()
            camera = nil
            _ = await systemAudio?.stop()
            systemAudio = nil
            _ = await channels.detach()
            try? await stream?.stopCapture()
            stream = nil
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

    /// "Add recording marker" (flag).
    public func addMarker() {
        guard phase == .recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        journal?.update { $0.markerUptimes.append(now) }
    }

    /// Stops recording and finalizes the folder; the movie ends up at `outputURL` (and the
    /// webcam beside it).
    public func finish(to outputURL: URL) async throws -> CaptureResult {
        guard phase == .recording || phase == .paused, let workDirectory else { throw CaptureError.notRecording }
        let wasPaused = phase == .paused
        phase = .finishing
        defer { phase = .idle }
        if !wasPaused { try await endSegment() }
        mouse.stop()
        _ = await camera?.stop()
        camera = nil
        _ = await systemAudio?.stop()
        systemAudio = nil
        try? await stream?.stopCapture()
        stream = nil
        journal?.close()
        journal = nil
        var result = try await RecordingFinalizer.finalize(folder: workDirectory)
        try Self.move(&result, to: outputURL)
        return result
    }

    /// Moves a finalized movie (and its webcam) next to `outputURL`.
    static func move(_ result: inout CaptureResult, to outputURL: URL) throws {
        if result.videoURL != outputURL {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: result.videoURL, to: outputURL)
            result.videoURL = outputURL
        }
        if let camera = result.cameraURL {
            let target = outputURL.deletingLastPathComponent().appendingPathComponent(RecordingFinalizer.cameraFileName)
            if camera != target {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: camera, to: target)
                result.cameraURL = target
            }
        }
    }

    /// Stops and deletes everything recorded so far.
    public func cancel() async {
        mouse.stop()
        _ = await camera?.stop()
        camera = nil
        _ = await systemAudio?.stop()
        systemAudio = nil
        for writer in await channels.detach() { await writer.finish() }
        try? await stream?.stopCapture()
        stream = nil
        journal?.close()
        journal = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        segments = []
        phase = .idle
    }

    // MARK: Sessions

    /// Opens the next session's channels and waits for its first frame.
    private func beginSegment() async throws {
        guard let workDirectory, let journal else { throw CaptureError.notRecording }
        let index = segments.count
        var writers: [SCStreamOutputType: SegmentedWriter] = [:]
        var entries: [RecordingMetadata.Channel] = []
        let width = Int(videoSize.width), height = Int(videoSize.height)
        let display = try SegmentedWriter(directory: workDirectory, name: "channel-1-display-\(index)", mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 6, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        writers[.screen] = display
        entries.append(.init(source: "display", playlist: display.name))
        if options.capturesSystemAudio && options.systemAudioProcessIDs == nil {
            let writer = try SegmentedWriter(directory: workDirectory, name: "channel-4-system-audio-\(index)", mediaType: .audio, outputSettings: SegmentedWriter.audioSettings)
            writers[.audio] = writer
            entries.append(.init(source: AudioSource.systemAudio.rawValue, playlist: writer.name))
        }
        if options.microphoneID != nil {
            let writer = try SegmentedWriter(directory: workDirectory, name: "channel-2-microphone-\(index)", mediaType: .audio, outputSettings: SegmentedWriter.audioSettings)
            writers[.microphone] = writer
            entries.append(.init(source: AudioSource.microphone.rawValue, playlist: writer.name))
        }
        for (_, writer) in writers {
            let name = writer.name
            writer.onStart = { start in
                Task { @MainActor in
                    journal.update { metadata in
                        guard let s = metadata.sessions.firstIndex(where: { $0.index == index }),
                              let c = metadata.sessions[s].channels.firstIndex(where: { $0.playlist == name }) else { return }
                        metadata.sessions[s].channels[c].startUptime = start
                    }
                }
            }
        }
        journal.update { $0.sessions.append(.init(index: index, channels: entries)) }
        let start = try await channels.attach(writers, timeout: 5)
        segments.append(Segment(startUptime: start))
        journal.update { metadata in
            if let s = metadata.sessions.firstIndex(where: { $0.index == index }) { metadata.sessions[s].startUptime = start }
        }
    }

    /// Closes the session's channels.
    private func endSegment() async throws {
        let writers = await channels.detach()
        guard !writers.isEmpty else { return }
        let endUptime = ProcessInfo.processInfo.systemUptime
        for writer in writers { await writer.finish() }
        guard !segments.isEmpty else { return }
        segments[segments.count - 1].endUptime = endUptime
        let index = segments.count - 1
        journal?.update { metadata in
            if let s = metadata.sessions.firstIndex(where: { $0.index == index }) { metadata.sessions[s].endUptime = endUptime }
        }
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
        flags = []
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
            if window.owningApplication?.bundleIdentifier == Self.screenContinuityBundleID {
                // iPhone Mirroring is always cropped to its phone screen: the window without its
                // 38 pt title bar and 8 pt borders.
                let inner = CGRect(x: 8, y: 38, width: max(window.frame.width - 16, 1), height: max(window.frame.height - 46, 1))
                sourceRect = inner
                originInPoints = CGPoint(x: window.frame.minX + inner.minX, y: window.frame.minY + inner.minY)
                sizeInPoints = inner.size
                flags = ["ScreenContinuity"]
            } else {
                originInPoints = window.frame.origin
                sizeInPoints = window.frame.size
            }
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
        configuration.capturesAudio = options.capturesSystemAudio && options.systemAudioProcessIDs == nil
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

    /// Rewrites `movie` with the first audio track of `audio` added after its own tracks.
    static func addAudioTrack(from audio: URL, to movie: URL) async throws {
        let base = AVURLAsset(url: movie)
        let extra = AVURLAsset(url: audio)
        let duration = try await base.load(.duration)
        let composition = AVMutableComposition()
        for track in try await base.load(.tracks) {
            guard let target = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        if let track = try await extra.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let length = min(try await extra.load(.duration), duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        }
        let joined = movie.deletingLastPathComponent().appendingPathComponent("joined-\(UUID().uuidString).mov")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.failed("Could not join the recording segments.")
        }
        try await session.export(to: joined, as: .mov)
        _ = try FileManager.default.replaceItemAt(movie, withItemAt: joined)
    }

}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.channels.failPending(error)
            if self.phase == .recording || self.phase == .paused { self.onUnexpectedStop?(error) }
        }
    }
}

/// Routes the stream's samples to the current session's channels, on its own queue.
final class StreamChannels: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "regrava.capture.channels", qos: .userInitiated)
    private var writers: [SCStreamOutputType: SegmentedWriter] = [:]
    private var waiter: CheckedContinuation<TimeInterval, Error>?

    /// Starts routing to `writers`; returns the host time of the first picture.
    func attach(_ writers: [SCStreamOutputType: SegmentedWriter], timeout: TimeInterval) async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.writers = writers
                self.waiter = continuation
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard let waiter = self.waiter else { return }
                self.waiter = nil
                self.writers = [:]
                waiter.resume(throwing: CaptureError.failed("The recording did not start. Check the Screen Recording permission."))
            }
        }
    }

    /// Stops routing; returns the writers to finish.
    func detach() async -> [SegmentedWriter] {
        await withCheckedContinuation { continuation in
            queue.async {
                let all = Array(self.writers.values)
                self.writers = [:]
                continuation.resume(returning: all)
            }
        }
    }

    func failPending(_ error: Error) {
        queue.async {
            self.waiter?.resume(throwing: error)
            self.waiter = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer = writers[type] else { return }
        if type == .screen {
            // Only complete frames carry a picture; idle ones repeat the last.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            guard writer.append(sampleBuffer) else { return }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            }
        } else {
            // Audio before the session's first picture is dropped.
            guard waiter == nil else { return }
            writer.append(sampleBuffer)
        }
    }
}

/// Screen frames need a consumer for a stream to run (audio-only streams ignore them).
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "regrava.capture.frames", qos: .userInitiated)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
