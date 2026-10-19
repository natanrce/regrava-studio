import Foundation

/// The crop window's model. Works in webcam pixels; the stored `crop01` is relative to the
/// whole, unmirrored webcam frame.
public struct CameraCropState: Sendable, Equatable {
    public static let minCropSize = 200.0
    /// Aspect lock choices of the toolbar; nil = "Any".
    public static let aspectRatioOptions: [(x: Double, y: Double)] = [(16, 9), (4, 3), (1, 1), (3, 4), (9, 16)]

    public let frame: Rect2
    public private(set) var crop: Rect2
    public private(set) var forcedAspectRatio: Vec2?

    /// Opens with the project's crop (mirrored into what the editor shows) and no aspect lock.
    public init(videoSize: Size2?, crop01: Rect2?, mirror: Bool) {
        frame = Rect2(x: 0, y: 0, width: videoSize?.width ?? 1280, height: videoSize?.height ?? 720)
        var c = crop01 ?? Self.full01
        if mirror { c = Self.mirrored(c) }
        crop = Rect2(x: c.x * frame.width, y: c.y * frame.height, width: c.width * frame.width, height: c.height * frame.height)
        forcedAspectRatio = nil
        crop = Self.constrain(crop, in: frame, aspectRatio: nil, minSize: Self.minCropSize)
    }

    public static let full01 = Rect2(x: 0, y: 0, width: 1, height: 1)

    public static func mirrored(_ r: Rect2) -> Rect2 { Rect2(x: 1 - r.x - r.width, y: r.y, width: r.width, height: r.height) }

    public var crop01: Rect2 {
        Rect2(x: crop.x / frame.width, y: crop.y / frame.height, width: crop.width / frame.width, height: crop.height / frame.height)
    }

    public var isTooSmall: Bool { crop.width < Self.minCropSize || crop.height < Self.minCropSize }

    private var aspectNumber: Double? { forcedAspectRatio.map { $0.x / $0.y } }

    /// `setNewCrop`: with constraints, or only kept inside the frame (the Size inputs).
    public mutating func setCrop(_ c: Rect2, applyConstraints: Bool = true) {
        crop = applyConstraints ? Self.constrain(c, in: frame, aspectRatio: aspectNumber, minSize: Self.minCropSize) : Self.clampMax(c, in: frame)
    }

    public mutating func setCrop01(_ c: Rect2, applyConstraints: Bool = true) {
        setCrop(Rect2(x: c.x * frame.width, y: c.y * frame.height, width: c.width * frame.width, height: c.height * frame.height), applyConstraints: applyConstraints)
    }

    public mutating func setForcedAspectRatio(_ ratio: Vec2?) {
        forcedAspectRatio = ratio
        crop = Self.constrain(crop, in: frame, aspectRatio: aspectNumber, minSize: Self.minCropSize)
    }

    /// Reset / double-click: whole frame, aspect lock off.
    public mutating func expandToFullSize() {
        forcedAspectRatio = nil
        crop = Self.constrain(frame, in: frame, aspectRatio: nil, minSize: Self.minCropSize)
    }

    /// The value to store on confirm: unmirrored, nil for the whole frame.
    public func confirmedCrop01(mirror: Bool) -> Rect2? {
        let c = mirror ? Self.mirrored(crop01) : crop01
        return c == Self.full01 ? nil : c
    }

    // MARK: Constraints

    private static func contains(_ b: Rect2, _ c: Rect2) -> Bool {
        b.x <= c.x && b.endX >= c.endX && b.y <= c.y && b.endY >= c.endY
    }

    /// Moved inside the bounds without resizing; an axis that cannot fit is left alone.
    static func shiftInside(_ c: Rect2, _ b: Rect2) -> Rect2 {
        let maxX = b.endX - c.width, maxY = b.endY - c.height
        return Rect2(x: maxX < b.x ? c.x : clamp(c.x, b.x, maxX), y: maxY < b.y ? c.y : clamp(c.y, b.y, maxY), width: c.width, height: c.height)
    }

    /// Shifted inside, else scaled down uniformly (keeping its origin) and shifted again.
    static func fitInside(_ c: Rect2, _ b: Rect2) -> Rect2 {
        if contains(b, c) { return c }
        let s1 = shiftInside(c, b)
        if contains(b, s1) { return s1 }
        let f = min(b.width / s1.width, b.height / s1.height)
        return shiftInside(Rect2(x: s1.x, y: s1.y, width: s1.width * f, height: s1.height * f), b)
    }

    /// Size limited to the bounds, then fitted.
    static func clampMax(_ c: Rect2, in b: Rect2) -> Rect2 {
        fitInside(Rect2(x: c.x, y: c.y, width: clamp(c.width, 0, b.width), height: clamp(c.height, 0, b.height)), b)
    }

    /// The aspect from the height, never growing either side.
    static func applyAspect(_ c: Rect2, _ ratio: Double) -> Rect2 {
        let w = c.height * ratio, h = c.height
        let m = max(w / c.width, h / c.height)
        return m <= 1 ? Rect2(x: c.x, y: c.y, width: w, height: h) : Rect2(x: c.x, y: c.y, width: w / m, height: h / m)
    }

    /// Size limit, minimum size, aspect lock, fit.
    static func constrain(_ c: Rect2, in b: Rect2, aspectRatio: Double?, minSize: Double) -> Rect2 {
        var r = clampMax(c, in: b)
        r.width = lowerFirstClamp(r.width, minSize, b.width)
        r.height = lowerFirstClamp(r.height, minSize, b.height)
        if let aspectRatio { r = applyAspect(r, aspectRatio) }
        return fitInside(r, b)
    }

    /// The clamp checks the lower bound first.
    private static func lowerFirstClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v < lo ? lo : v > hi ? hi : v
    }
}
