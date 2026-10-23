import Foundation

/// "Sensitive Data" covers the area; "Highlight" darkens everything around it.
public enum MaskType: String, Codable, CaseIterable, Sendable {
    case sensitiveData = "sensitive-data"
    case highlight
}

/// A mask range: a rectangle over the recording during a source time range.
public struct MaskRange: Codable, Hashable, Sendable, Identifiable {
    public static let minimumDurationMs = 500.0
    public static let initialDurationMs = 3000.0
    /// Default rectangle size, in recording pixels.
    public static let defaultSize = Size2(width: 350, height: 80)

    public var id: UUID
    public var startMs: Double
    public var endMs: Double
    public var isDisabled: Bool
    /// Rectangles in recording pixels; only the first is used.
    public var bounds: [Rect2]
    /// Stored (default 32) but not editable.
    public var blur: Double
    public var type: MaskType
    public var highlightMaskOpacity: Double

    public init(
        id: UUID = UUID(),
        startMs: Double,
        endMs: Double,
        isDisabled: Bool = false,
        bounds: [Rect2],
        blur: Double = 32,
        type: MaskType = .sensitiveData,
        highlightMaskOpacity: Double = 0.5
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.isDisabled = isDisabled
        self.bounds = bounds
        self.blur = blur
        self.type = type
        self.highlightMaskOpacity = highlightMaskOpacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        startMs = try c.decode(Double.self, forKey: .startMs)
        endMs = try c.decode(Double.self, forKey: .endMs)
        isDisabled = c.value(.isDisabled, default: false)
        bounds = c.value(.bounds, default: [])
        blur = c.value(.blur, default: 32)
        type = c.value(.type, default: .sensitiveData)
        highlightMaskOpacity = c.value(.highlightMaskOpacity, default: 0.5)
    }

    public var durationMs: Double { endMs - startMs }
    public var firstBound: Rect2? { bounds.first }
    public func contains(_ t: Double) -> Bool { t >= startMs && t <= endMs }
    /// `getCanShow`.
    public var canShow: Bool { !isDisabled && firstBound != nil }
    /// `isGreedy`: sensitive data stays fully covered while in range.
    public var isGreedy: Bool { type == .sensitiveData && canShow }

    /// Window in which a mask can take over: sensitive data 200 ms early.
    public func isWithinShowWindow(_ t: Double) -> Bool {
        guard canShow else { return false }
        let start = isGreedy ? startMs - 200 : startMs
        return start <= t && t <= endMs + 200
    }
}

public extension Project {
    /// Rectangle for a new mask: the last mask's, else 350×80 centred.
    var defaultMaskBounds: [Rect2] {
        if let last = masks.last, !last.bounds.isEmpty { return last.bounds }
        // Centred on the cropped size without the crop's origin.
        let size = croppedVideoSize
        let width = min(size.width, MaskRange.defaultSize.width)
        let height = min(size.height, MaskRange.defaultSize.height)
        return [Rect2(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)]
    }

    /// Rectangle of a click-placed mask: default size centred on the point, kept inside.
    func clickedMaskBounds(at point01: Vec2) -> Rect2 {
        // `point01` is in the crop; kept inside it.
        let crop = screenCropRect
        let size = crop.size
        let width = min(size.width, MaskRange.defaultSize.width)
        let height = min(size.height, MaskRange.defaultSize.height)
        return Rect2(
            x: crop.x + clamp(point01.x * size.width - width / 2, 0, size.width - width),
            y: crop.y + clamp(point01.y * size.height - height / 2, 0, size.height - height),
            width: width,
            height: height
        )
    }

    var sortedMasks: [MaskRange] { masks.sorted { $0.startMs < $1.startMs } }
}

/// What the renderer needs to draw the mask at one instant.
public struct MaskFrame: Hashable, Sendable {
    /// Rectangle as a fraction of the recording.
    public var bounds01: Rect2
    /// Corner radius as a fraction of the recording width (16 px).
    public var borderRadius01: Double
    public var type: MaskType
    public var highlightOpacity: Double
    /// Sensitive data in range: fully applied regardless of the fade.
    public var active: Bool
    public var opacity: Double

    /// Effective opacity and whether the area is covered (mode 1) or darkened around.
    public var effectiveOpacity: Double { active ? 1 : clamp(opacity, 0, 1) }
    public var coversArea: Bool { active || type == .sensitiveData }
    /// Nothing to draw below 1% opacity.
    public var isVisible: Bool { effectiveOpacity > 0.01 }

    static let none = MaskFrame(bounds01: Rect2(x: 0, y: 0, width: 0, height: 0), borderRadius01: 0, type: .highlight, highlightOpacity: 0, active: false, opacity: 0)
}

/// Mask animation over the timeline.
struct MaskAnimator {
    static let cornerRadius = 16.0
    /// Fade spring: Rapid limited to 200 ms (`Eb = ge(200, pe)`).
    static let fadeSpring = SpringMath.limited(toDurationMs: 200, SpringConfig(stiffness: 530, damping: 40, mass: 1))

    let masks: [MaskRange]
    let recordingSize: Size2
    private var bounds = SpringRect(Rect2(x: 0, y: 0, width: 0, height: 0))
    private var radius = SpringValue(0)
    private var highlight = SpringValue(0)
    private var opacity = SpringValue(0)

    init(masks: [MaskRange], recordingSize: Size2) {
        self.masks = masks.sorted { $0.startMs < $1.startMs }
        self.recordingSize = recordingSize
    }

    /// Mask in charge at `t`.
    func current(at t: Double) -> MaskRange? {
        let here = masks.last { $0.contains(t) }
        let next = masks.first { $0.startMs >= t && !$0.contains(t) }
        let previous = masks.last { $0.endMs <= t && !$0.contains(t) }
        if let here, here.isGreedy { return here }
        if let next {
            if here == nil, let previous, previous.canShow, next.canShow, next.startMs - previous.endMs < 400 { return next }
            if next.isGreedy && next.isWithinShowWindow(t) { return next }
        }
        if let here, here.canShow { return here }
        if let previous, previous.isWithinShowWindow(t) { return previous }
        return nil
    }

    /// Spring for the rectangle: instant inside a sensitive mask or when there is no
    /// visible previous mask close by; otherwise a default spring limited to the gap.
    func boundsSpring(for mask: MaskRange, at t: Double) -> SpringConfig {
        if mask.isGreedy && mask.contains(t) { return .instant }
        guard let previous = masks.last(where: { $0.endMs <= mask.startMs && $0.id != mask.id }), previous.canShow else { return .instant }
        let gap = mask.startMs - previous.endMs
        if gap >= 400 { return .instant }
        return SpringMath.limited(toDurationMs: mask.isGreedy ? gap : gap + 200, SpringConfig())
    }

    mutating func frame(at t: Double, stepMs: Double, first: Bool) -> MaskFrame {
        let mask = current(at: t)
        // Cover opacity: 1 until the mask ends, then 0.
        let opacityTarget: Double = mask.map { t > $0.endMs ? 0 : 1 } ?? 0
        opacity.setTarget(opacityTarget, config: Self.fadeSpring)
        if first { opacity.snapToTarget() } else { opacity.advance(by: stepMs, config: Self.fadeSpring) }

        guard let mask, mask.canShow, let rect = mask.firstBound else {
            // No options; values are not animated.
            bounds = SpringRect(Rect2(x: 0, y: 0, width: 0, height: 0))
            radius = SpringValue(0)
            highlight = SpringValue(0)
            var none = MaskFrame.none
            none.opacity = opacity.value
            return none
        }
        let target = Rect2(
            x: rect.x / recordingSize.width,
            y: rect.y / recordingSize.height,
            width: rect.width / recordingSize.width,
            height: rect.height / recordingSize.height
        )
        let spring = boundsSpring(for: mask, at: t)
        let radiusTarget = Self.cornerRadius / recordingSize.width
        if first {
            bounds = SpringRect(target)
            radius = SpringValue(radiusTarget)
            highlight = SpringValue(mask.highlightMaskOpacity)
        } else {
            bounds.advance(toward: target, config: spring, milliseconds: stepMs)
            radius.advance(toward: radiusTarget, config: spring, milliseconds: stepMs)
            highlight.advance(toward: mask.highlightMaskOpacity, config: spring, milliseconds: stepMs)
        }
        return MaskFrame(
            bounds01: bounds.rect,
            borderRadius01: radius.value,
            type: mask.type,
            highlightOpacity: highlight.value,
            active: mask.isGreedy && mask.contains(t),
            opacity: opacity.value
        )
    }
}
