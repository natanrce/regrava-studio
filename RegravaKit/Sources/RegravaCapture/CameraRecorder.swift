@preconcurrency import AVFoundation
import Foundation

/// Records the webcam into its own movie while the screen is recorded.
///
/// The camera runs continuously (through pauses); sample times use the host clock, the same
/// clock as `ProcessInfo.systemUptime`, so the file can be cut to the screen's segments.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Result {
        var url: URL
        /// Uptime of the movie's first frame.
        var startUptime: TimeInterval
        var size: CGSize
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "regrava.camera.recorder")
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startUptime: TimeInterval?
    private var size: CGSize = .zero
    private var isStopping = false

    init(url: URL) {
        self.url = url
    }

    /// Opens the camera at the largest format no taller than `maxHeight` and starts writing.
    func start(deviceID: String, maxHeight: Int) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureError.failed("The selected camera is not connected.")
        }
        let formats = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(d.height) <= maxHeight
        }
        if let best = formats.max(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }) {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        }
        let deviceInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.failed("Could not record the camera.")
        }
        session.addInput(deviceInput)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        try? FileManager.default.removeItem(at: url)
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isStopping, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6],
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            self.writer = writer
            self.input = input
            startUptime = time.seconds
            size = CGSize(width: width, height: height)
        }
        if let input, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Stops the camera and closes the movie; nil when nothing was recorded.
    func stop() async -> Result? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isStopping = true
                continuation.resume()
            }
        }
        session.stopRunning()
        guard let writer, let input, let startUptime else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return Result(url: url, startUptime: startUptime, size: size)
    }
}
