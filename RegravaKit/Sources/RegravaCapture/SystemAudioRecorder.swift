@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// System audio of selected apps only, in its own stream. An app filter on the screen's own
/// stream would also limit the picture to those apps, so the sound is captured apart and
/// written to its own file, on the host clock so it can be cut to the screen's segments.
final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Result {
        var url: URL
        /// Uptime of the file's first sample.
        var startUptime: TimeInterval
    }

    private let url: URL
    private let queue = DispatchQueue(label: "regrava.capture.system-audio", qos: .userInitiated)
    private let frames = FrameSink()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startUptime: TimeInterval?
    private var isStopping = false

    init(url: URL) {
        self.url = url
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
        try? FileManager.default.removeItem(at: url)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !isStopping, sampleBuffer.isValid else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            self.writer = writer
            self.input = input
            startUptime = time.seconds
        }
        if let input, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    /// Stops the stream and closes the file; nil when no sound arrived.
    func stop() async -> Result? {
        try? await stream?.stopCapture()
        stream = nil
        let (writer, input, start): (AVAssetWriter?, AVAssetWriterInput?, TimeInterval?) = await withCheckedContinuation { continuation in
            queue.async {
                self.isStopping = true
                continuation.resume(returning: (self.writer, self.input, self.startUptime))
            }
        }
        guard let writer, let input, let start else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return Result(url: url, startUptime: start)
    }
}
