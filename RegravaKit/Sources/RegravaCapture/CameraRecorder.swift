@preconcurrency import AVFoundation
import Foundation

/// Records the webcam into its own channel (`channel-3-webcam-0`, an HLS playlist) while the
/// screen is recorded.
///
/// The camera runs continuously (through pauses); sample times use the host clock, the same
/// clock as `ProcessInfo.systemUptime`, so the file can be cut to the screen's segments.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "regrava.camera.recorder")
    /// `startRunning`/`stopRunning` block until the camera is up or down; they run here.
    private let sessionQueue = DispatchQueue(label: "regrava.camera.session", qos: .userInitiated)
    private let directory: URL
    private let name: String
    private var writer: SegmentedWriter?
    /// First frame: its host time and size (for the recording's metadata).
    var onStart: (@Sendable (TimeInterval, CGSize) -> Void)?
    private var isStopping = false

    init(directory: URL, name: String = "channel-3-webcam-0") {
        self.directory = directory
        self.name = name
    }

    /// Opens the camera at the largest format no taller than `maxHeight` and starts writing.
    func start(deviceID: String, maxHeight: Int) async throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureError.failed("The selected camera is not connected.")
        }
        if let best = CameraFormats.best(of: device, maxHeight: maxHeight) {
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
        await run { $0.startRunning() }
    }

    private func run(_ change: @escaping @Sendable (AVCaptureSession) -> Void) async {
        let session = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                change(session)
                continuation.resume()
            }
        }
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
            onStart?(time.seconds, CGSize(width: width, height: height))
        }
        writer?.append(sampleBuffer)
    }

    /// Stops the camera and closes the movie, if anything was recorded.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isStopping = true
                continuation.resume()
            }
        }
        await run { $0.stopRunning() }
        await writer?.finish()
    }
}

/// Choosing the format a camera is opened at.
public enum CameraFormats {
    /// The camera's largest format no taller than `maxHeight`.
    public static func best(of device: AVCaptureDevice, maxHeight: Int) -> AVCaptureDevice.Format? {
        device.formats
            .filter { Int(CMVideoFormatDescriptionGetDimensions($0.formatDescription).height) <= maxHeight }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
    }
}
