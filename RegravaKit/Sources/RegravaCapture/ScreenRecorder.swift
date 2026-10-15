import AVFoundation
import AppKit
import RegravaCore
@preconcurrency import ScreenCaptureKit

public struct CaptureOptions: Hashable, Sendable {
    public var fps: Int
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool

    public init(fps: Int = 60, capturesSystemAudio: Bool = false, capturesMicrophone: Bool = false) {
        self.fps = fps
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
    }
}

public struct CaptureResult: Sendable {
    public var videoURL: URL
    public var mouseEvents: [MouseEvent]
    public var videoSize: Size2
    public var pointPixelScale: Double
    public var durationMs: Double
    public var fps: Int
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: CGDirectDisplayID
    public var name: String
    public var widthPoints: Int
    public var heightPoints: Int
}

public enum CaptureError: LocalizedError {
    case displayNotFound
    case notRecording
    case alreadyRecording
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The selected display is no longer available."
        case .notRecording: return "No recording is in progress."
        case .alreadyRecording: return "A recording is already in progress."
        case .failed(let message): return message
        }
    }
}

/// Records one display to a movie file with ScreenCaptureKit, hiding the system cursor so it
/// can be redrawn (smoothed and scaled) at render time, while tracking mouse events.
@MainActor
public final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let mouse = MouseTracker()
    private let frameSink = FrameSink()

    private var outputURL: URL?
    private var displayBounds: CGRect = .zero
    private var pointPixelScale: Double = 1
    private var videoSize = Size2(width: 0, height: 0)
    private var fps = 60
    private var startUptime: TimeInterval?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    public private(set) var isRecording = false

    public override init() {
        super.init()
    }

    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            return DisplayInfo(
                id: display.displayID,
                name: screen?.localizedName ?? "Display \(display.displayID)",
                widthPoints: display.width,
                heightPoints: display.height
            )
        }
    }

    public func start(displayID: CGDirectDisplayID, options: CaptureOptions, outputURL: URL) async throws {
        guard !isRecording else { throw CaptureError.alreadyRecording }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        // Keep our own windows out of the recording.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        pointPixelScale = Double(filter.pointPixelScale)
        let width = Int((Double(display.width) * pointPixelScale).rounded())
        let height = Int((Double(display.height) * pointPixelScale).rounded())
        videoSize = Size2(width: Double(width), height: Double(height))
        displayBounds = CGDisplayBounds(displayID)
        fps = options.fps

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 6
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.captureMicrophone = options.capturesMicrophone

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)

        try? FileManager.default.removeItem(at: outputURL)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput
        self.outputURL = outputURL
        startUptime = nil

        mouse.start()
        do {
            try await stream.startCapture()
            try await waitForRecordingStart(timeoutSeconds: 5)
        } catch {
            mouse.stop()
            self.stream = nil
            self.recordingOutput = nil
            throw error
        }
        isRecording = true
    }

    public func stop() async throws -> CaptureResult {
        guard isRecording, let stream, let outputURL else { throw CaptureError.notRecording }
        isRecording = false
        let samples = mouse.stop()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
            Task { @MainActor in
                do {
                    try await stream.stopCapture()
                } catch {
                    self.resumeFinish(with: error)
                }
                // Safety net in case the finish callback never arrives.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.resumeFinish(with: nil)
            }
        }
        self.stream = nil
        recordingOutput = nil

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        let events = MouseTracker.convert(
            samples,
            startUptime: startUptime ?? samples.first?.uptime ?? 0,
            displayBounds: displayBounds,
            pointPixelScale: pointPixelScale
        )
        return CaptureResult(
            videoURL: outputURL,
            mouseEvents: events,
            videoSize: videoSize,
            pointPixelScale: pointPixelScale,
            durationMs: duration.seconds * 1000,
            fps: fps
        )
    }

    private func waitForRecordingStart(timeoutSeconds: Double) async throws {
        if startUptime != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self.resumeStart(with: CaptureError.failed("The recording did not start. Check the Screen Recording permission."))
            }
        }
    }

    private func resumeStart(with error: Error?) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func resumeFinish(with error: Error?) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.resumeStart(with: error)
            self.resumeFinish(with: error)
        }
    }

    nonisolated public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let uptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            self.startUptime = uptime
            self.resumeStart(with: nil)
        }
    }

    nonisolated public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish(with: nil) }
    }

    nonisolated public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.resumeStart(with: error)
            self.resumeFinish(with: error)
        }
    }
}

/// Screen frames must have a consumer for the stream to run; the file is written by
/// `SCRecordingOutput`, so frames are simply dropped here.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "regrava.capture.frames", qos: .userInitiated)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
