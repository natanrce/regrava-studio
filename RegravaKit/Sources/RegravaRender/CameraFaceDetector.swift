@preconcurrency import AVFoundation
import Foundation
import RegravaCore
import Vision

/// Finds the face in the webcam movie every `FaceTracking.intervalMs` with Apple Vision, in place
/// of the pico cascade worker. each sample keeps one face, the most confident one; misses are
/// kept with confidence 0.
public enum CameraFaceDetector {
    /// Continues `previous` when given; reports partial results every ~2 s of camera time.
    public static func detect(
        movie: URL,
        previous: CameraFaces? = nil,
        progress: @Sendable (CameraFaces) -> Void = { _ in }
    ) async throws -> CameraFaces {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return CameraFaces(intervalMs: FaceTracking.intervalMs, analyzedUntilMs: 0, isComplete: true)
        }
        let durationMs = try await asset.load(.duration).seconds * 1000
        var faces = previous ?? CameraFaces(intervalMs: FaceTracking.intervalMs)
        if faces.isComplete { return faces }
        let interval = faces.intervalMs
        var next = faces.samples.last.map { $0.timeMs + interval } ?? 0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // Start a little early so the frame at or before `next` is available.
        let startMs = max(next - 500, 0)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startMs / 1000, preferredTimescale: 600), end: CMTime(seconds: durationMs / 1000, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var current: (timeMs: Double, buffer: CVPixelBuffer)?
        var lastReport = next
        func analyse(_ t: Double, _ buffer: CVPixelBuffer?) {
            var sample = CameraFaceSample(timeMs: t, confidence: 0, rect: nil)
            if let buffer {
                let request = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                if let best = request.results?.max(by: { $0.confidence < $1.confidence }) {
                    let b = best.boundingBox
                    sample.confidence = Double(best.confidence)
                    // Vision's origin is bottom-left; samples use the top-left one.
                    sample.rect = Rect2(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                }
            }
            faces.samples.append(sample)
            faces.analyzedUntilMs = t
        }

        while next < durationMs {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000
            // Every sample time before this frame uses the frame shown at that time.
            while next < time && next < durationMs {
                analyse(next, current?.buffer)
                next += interval
            }
            current = (time, image)
            if faces.analyzedUntilMs - lastReport >= 2000 {
                lastReport = faces.analyzedUntilMs
                progress(faces)
            }
        }
        while next < durationMs {
            try Task.checkCancellation()
            analyse(next, current?.buffer)
            next += interval
        }
        faces.analyzedUntilMs = durationMs
        faces.isComplete = true
        progress(faces)
        return faces
    }
}
