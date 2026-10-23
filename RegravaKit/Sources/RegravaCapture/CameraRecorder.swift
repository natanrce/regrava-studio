@preconcurrency import AVFoundation
import Foundation

/// Records the webcam into its own channel (`channel-3-webcam-0`, an HLS playlist) while the
/// screen is recorded.
///
/// The camera runs continuously (through pauses); sample times use the host clock, the same
/// clock as `ProcessInfo.systemUptime`, so the file can be cut to the screen's segments.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Result {
        /// The flattened-later playlist.
        var playlist: URL
        /// Uptime of the movie's first frame.
        var startUptime: TimeInterval
        var size: CGSize
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "regrava.camera.recorder")
    private let directory: URL
    private let name: String
    private var writer: SegmentedWriter?
    /// First frame: its host time and size (for the recording's metadata).
    var onStart: (@Sendable (TimeInterval, CGSize) -> Void)?
    private var startUptime: TimeInterval?
    private var size: CGSize = .zero
    private var isStopping = false

    init(directory: URL, name: String = "channel-3-webcam-0") {
        self.directory = directory
        self.name = name
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
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isStopping, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            guard let writer = try? SegmentedWriter(directory: directory, name: name, mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6],
            ]) else { return }
            self.writer = writer
            startUptime = time.seconds
            size = CGSize(width: width, height: height)
            onStart?(time.seconds, size)
        }
        writer?.append(sampleBuffer)
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
        guard let writer, let startUptime else { return nil }
        await writer.finish()
        return Result(playlist: writer.playlistURL, startUptime: startUptime, size: size)
    }
}
