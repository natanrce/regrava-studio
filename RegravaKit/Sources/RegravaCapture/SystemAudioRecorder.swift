@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// System audio of selected apps only, in its own stream. An app filter on the screen's own
/// stream would also limit the picture to those apps, so the sound is captured apart and
/// written to its own file, on the host clock so it can be cut to the screen's segments.
final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let directory: URL
    private let name: String
    /// First sample's host time (for the recording's metadata).
    var onStart: (@Sendable (TimeInterval) -> Void)?
    private let queue = DispatchQueue(label: "regrava.capture.system-audio", qos: .userInitiated)
    private let frames = FrameSink()
    private var stream: SCStream?
    private var writer: SegmentedWriter?
    private var isStopping = false

    init(directory: URL, name: String = "channel-4-system-audio-apps-0") {
        self.directory = directory
        self.name = name
    }

    /// Validation and lookup: an empty list is refused, and only pids still found among the
    /// shareable apps are recorded.
    func start(processIDs: [pid_t], content: SCShareableContent) async throws {
        guard !processIDs.isEmpty else { throw CaptureError.failed("SystemAudio: includedProcessIds cannot be set to empty array") }
        let apps = content.applications.filter { processIDs.contains($0.processID) }
        guard !apps.isEmpty, let display = content.displays.first else {
            throw CaptureError.failed("SystemAudio: None of the includedProcessIds can be found, cannot record audio ")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !isStopping, sampleBuffer.isValid else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard let writer = try? SegmentedWriter(directory: directory, name: name, mediaType: .audio, outputSettings: SegmentedWriter.audioSettings) else { return }
            self.writer = writer
            onStart?(time.seconds)
        }
        writer?.append(sampleBuffer)
    }

    /// Stops the stream and closes the file, if any sound arrived.
    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        let writer: SegmentedWriter? = await withCheckedContinuation { continuation in
            queue.async {
                self.isStopping = true
                continuation.resume(returning: self.writer)
            }
        }
        await writer?.finish()
    }
}
