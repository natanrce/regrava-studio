import Foundation

/// `crop`: the kept part of the screen recording, in 0…1 of it. Always saved; a missing or
/// invalid rect resets to the whole recording, without clamping.
public struct ScreenCropConfig: Codable, Hashable, Sendable {
    public var rect01: Rect2

    public static let full = Rect2(x: 0, y: 0, width: 1, height: 1)

    public init(rect01: Rect2 = ScreenCropConfig.full) { self.rect01 = rect01 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let r = c.value(.rect01, default: ScreenCropConfig.full)
        let valid = [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0
        rect01 = valid ? r : ScreenCropConfig.full
    }

    public var isFull: Bool { rect01 == Self.full }
}

public extension Project {
    /// `changeCrop`: not for device recordings, iPhone Mirroring (cropped when recorded) or a
    /// device frame.
    var canChangeCrop: Bool {
        !(recording.isExternalDeviceMode || recording.isScreenContinuity || isUsingDeviceFrame)
    }

    /// The crop in effect, 0…1 (full when it can't change).
    var screenCrop01: Rect2 { canChangeCrop ? crop.rect01 : ScreenCropConfig.full }

    /// The crop in recorded-video pixels.
    var screenCropRect: Rect2 {
        let c = screenCrop01, v = recording.videoSize
        return Rect2(x: c.x * v.width, y: c.y * v.height, width: max(1, c.width * v.width), height: max(1, c.height * v.height))
    }

    /// The recording as laid out: its cropped size (`recordingBodySize`).
    var croppedVideoSize: Size2 { screenCropRect.size }

    /// The project in the crop's space: mouse events and mask bounds shifted to the crop's
    /// origin, the video the crop's size. Layout, cursor, zooms and the loupe work in it; events
    /// outside the crop keep their positions (not clamped).
    var screenCropSpace: Project {
        guard !screenCrop01.isFull01 else { return self }
        let origin = screenCropRect
        var p = self
        p.recording.videoSize = origin.size
        p.crop = ScreenCropConfig()
        p.mouseEvents = mouseEvents.map { event in
            var e = event
            e.position = Vec2(event.position.x - origin.x, event.position.y - origin.y)
            return e
        }
        p.masks = masks.map { mask in
            var m = mask
            m.bounds = mask.bounds.map { Rect2(x: $0.x - origin.x, y: $0.y - origin.y, width: $0.width, height: $0.height) }
            return m
        }
        return p
    }
}

extension Rect2 {
    var isFull01: Bool { self == ScreenCropConfig.full }
}
