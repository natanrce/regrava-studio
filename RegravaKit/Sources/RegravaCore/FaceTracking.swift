import Foundation

// Camera face tracking: the webcam pans so the face sits at the centre of the camera frame.
// Pan only: the face size is never used.

/// One detection sample: at most one face, its rect normalised to the camera frame (top-left
/// origin, unmirrored, uncropped).
public struct CameraFaceSample: Codable, Hashable, Sendable {
    public var timeMs: Double
    public var confidence: Double
    public var rect: Rect2?

    public init(timeMs: Double, confidence: Double, rect: Rect2?) {
        self.timeMs = timeMs
        self.confidence = confidence
        self.rect = rect
    }
}

/// Detection results of the webcam movie, stored in the project as `camera-faces_v1.json`.
public struct CameraFaces: Codable, Hashable, Sendable {
    public static let fileName = "camera-faces_v1.json"

    public var intervalMs: Double
    public var samples: [CameraFaceSample]
    /// Camera time analysed so far, and whether the whole movie is done (`isSettled`).
    public var analyzedUntilMs: Double
    public var isComplete: Bool

    public static func url(bundle: URL) -> URL { bundle.appendingPathComponent(fileName) }

    public static func load(bundle: URL) -> CameraFaces? {
        guard let data = try? Data(contentsOf: url(bundle: bundle)) else { return nil }
        return try? JSONDecoder().decode(CameraFaces.self, from: data)
    }

    public func save(bundle: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(bundle: bundle), options: .atomic)
    }

    public init(intervalMs: Double, samples: [CameraFaceSample] = [], analyzedUntilMs: Double = 0, isComplete: Bool = false) {
        self.intervalMs = intervalMs
        self.samples = samples
        self.analyzedUntilMs = analyzedUntilMs
        self.isComplete = isComplete
    }
}

public enum FaceTracking {
    /// Sampling interval: 100 ms, matching the 100 ms readiness window. A Regrava Studio choice.
    public static let intervalMs = 100.0
    /// Kept samples need a confidence above this. The threshold applies to Apple Vision's confidence.
    public static let confidenceThreshold = 0.5
    /// The focal point's own spring.
    public static let spring = SpringConfig(stiffness: 170, damping: 50, mass: 3)
    /// Tracking off and on without a usable face yet.
    public static let disabledCenter = Vec2(0.5, 0.5)
    public static let noFaceCenter = Vec2(0.5, 0.33)

    /// Confident samples, sorted by time (`confidentFaces`).
    public static func confident(_ faces: CameraFaces?) -> [CameraFaceSample]? {
        guard let faces else { return nil }
        return faces.samples.filter { $0.confidence > confidenceThreshold }.sorted { $0.timeMs < $1.timeMs }
    }

    /// The last confident face at or before the camera time, held when lost, re-expressed
    /// inside the crop.
    public static func faceCenter01(confident: [CameraFaceSample]?, cameraTimeMs: Double, crop01: Rect2?) -> Vec2 {
        guard let confident else { return noFaceCenter }
        var lo = 0, hi = confident.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if confident[mid].timeMs <= cameraTimeMs { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, let rect = confident[lo - 1].rect else { return noFaceCenter }
        return pointIntoCrop(rect.center, crop01)
    }

    public static func pointIntoCrop(_ p: Vec2, _ crop01: Rect2?) -> Vec2 {
        guard let c = crop01, c != Rect2(x: 0, y: 0, width: 1, height: 1) else { return p }
        guard c.width > 0, c.height > 0 else { return Vec2(0.5, 0.5) }
        return Vec2(clamp((p.x - c.x) / c.width, 0, 1), clamp((p.y - c.y) / c.height, 0, 1))
    }

    /// One axis of a cover-filled image moved so the focal point lands at the frame centre,
    /// clamped so the image still covers the frame.
    public static func focalAxis(imageOrigin: Double, imageLength: Double, frameOrigin: Double, frameLength: Double, focal01: Double) -> Double {
        guard imageLength - frameLength > 0 else { return imageOrigin }
        return clamp(frameOrigin + frameLength / 2 - focal01 * imageLength, frameOrigin + frameLength - imageLength, frameOrigin)
    }
}
