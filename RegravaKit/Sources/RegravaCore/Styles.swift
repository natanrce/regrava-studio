import Foundation

// Project look & motion settings, with the options and defaults. Every config decodes
// missing keys to defaults so older projects keep opening.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }
}

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(hex: value)
    }

    public var hexString: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Background (Section A)

public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case wallpaper = "system"
    case gradient
    case color
    case image
    case unsplash

    public var label: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .gradient: return "Gradient"
        case .color: return "Color"
        case .image: return "Image"
        case .unsplash: return "Unsplash"
        }
    }
}

public struct BackgroundConfig: Codable, Hashable, Sendable {
    public var kind: BackgroundKind
    public var color: RGBA
    public var gradientFrom: RGBA
    public var gradientTo: RGBA
    /// Image copied into the project folder.
    public var imageFileName: String?
    /// 0–100 px.
    public var blur: Double

    public init(
        kind: BackgroundKind = .gradient,
        color: RGBA = RGBA(hex: 0x4776E6),
        gradientFrom: RGBA = RGBA(hex: 0x4776E6),
        gradientTo: RGBA = RGBA(hex: 0x8E54E9),
        imageFileName: String? = nil,
        blur: Double = 0
    ) {
        self.kind = kind
        self.color = color
        self.gradientFrom = gradientFrom
        self.gradientTo = gradientTo
        self.imageFileName = imageFileName
        self.blur = blur
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundConfig()
        kind = c.value(.kind, default: d.kind)
        color = c.value(.color, default: d.color)
        gradientFrom = c.value(.gradientFrom, default: d.gradientFrom)
        gradientTo = c.value(.gradientTo, default: d.gradientTo)
        imageFileName = c.value(.imageFileName, default: d.imageFileName)
        blur = c.value(.blur, default: d.blur)
    }

    /// Gradient presets for the swatch grid (8 columns). These are this app's own.
    public static let gradientPresets: [(RGBA, RGBA)] = [
        (0x4776E6, 0x8E54E9), (0x6A11CB, 0x2575FC), (0xFF9A8B, 0xFF6A88), (0x0BA360, 0x3CBA92),
        (0x1E3C72, 0x2A5298), (0xF7971E, 0xFFD200), (0xEE0979, 0xFF6A00), (0x00C6FF, 0x0072FF),
        (0x8E2DE2, 0x4A00E0), (0xF953C6, 0xB91D73), (0x11998E, 0x38EF7D), (0xFC466B, 0x3F5EFB),
        (0x434343, 0x000000), (0xC33764, 0x1D2671), (0x56CCF2, 0x2F80ED), (0xF2994A, 0xF2C94C),
    ].map { (RGBA(hex: $0.0), RGBA(hex: $0.1)) }
}

// MARK: - Frame (Sections B and C)

public struct InsetConfig: Codable, Hashable, Sendable {
    /// 0 = off; 0.125–24 when on.
    public var size: Double
    public var color: RGBA
    public var alpha: Double
    public var origin01: Vec2

    public init(size: Double = 0, color: RGBA = RGBA(hex: 0x888888), alpha: Double = 0.25, origin01: Vec2 = .center01) {
        self.size = size
        self.color = color
        self.alpha = alpha
        self.origin01 = origin01
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InsetConfig()
        size = c.value(.size, default: d.size)
        color = c.value(.color, default: d.color)
        alpha = c.value(.alpha, default: d.alpha)
        origin01 = c.value(.origin01, default: d.origin01)
    }

    public var isOn: Bool { size > 0 }

    /// Settings used when the inset is switched on.
    public static let enabledDefault = InsetConfig(size: 4, color: RGBA(hex: 0x888888), alpha: 0.25, origin01: .center01)
}

public struct ShadowConfig: Codable, Hashable, Sendable {
    /// 0–0.6.
    public var intensity: Double
    public var isDirectional: Bool
    /// 0–100.
    public var distance: Double
    /// 0–180 degrees.
    public var angle: Double
    /// 0–30.
    public var blur: Double

    public init(intensity: Double = 0.3, isDirectional: Bool = true, distance: Double = 25, angle: Double = 45, blur: Double = 20) {
        self.intensity = intensity
        self.isDirectional = isDirectional
        self.distance = distance
        self.angle = angle
        self.blur = blur
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShadowConfig()
        intensity = c.value(.intensity, default: d.intensity)
        isDirectional = c.value(.isDirectional, default: d.isDirectional)
        distance = c.value(.distance, default: d.distance)
        angle = c.value(.angle, default: d.angle)
        blur = c.value(.blur, default: d.blur)
    }
}

/// Output aspect ratios of the "Output aspect ratio" picker.
public struct OutputAspect: Hashable, Sendable {
    public var label: String
    /// nil = Auto (recording + padding).
    public var ratio: Double?
    public var tip: String?

    public static let all: [OutputAspect] = [
        OutputAspect(label: "Auto", ratio: nil, tip: "Recording + Padding"),
        OutputAspect(label: "Wide", ratio: 16.0 / 9, tip: "Horizontal video not cropped on any major social media platform"),
        OutputAspect(label: "Square", ratio: 1, tip: nil),
        OutputAspect(label: "Classic", ratio: 4.0 / 3, tip: nil),
        OutputAspect(label: "Vertical", ratio: 9.0 / 16, tip: "Tiktok, Intagram stories, etc."),
        OutputAspect(label: "Tall", ratio: 3.0 / 4, tip: nil),
        OutputAspect(label: "Portrait", ratio: 4.0 / 5, tip: "Optimized for Instagram and Facebook feeds"),
    ]

    public var ratioLabel: String? {
        switch label {
        case "Wide": return "16:9"
        case "Square": return "1:1"
        case "Classic": return "4:3"
        case "Vertical": return "9:16"
        case "Tall": return "3:4"
        case "Portrait": return "4:5"
        default: return nil
        }
    }
}

public struct StyleConfig: Codable, Hashable, Sendable {
    /// nil = Auto (recording + padding).
    public var aspectRatio: Double?
    /// Padding as a fraction of the canvas' shortest side (0–0.25).
    public var paddingRatio: Double
    /// "Screen rounded corners", canvas pixels at rest (0–128).
    public var cornerRadius: Double
    public var inset: InsetConfig
    public var shadow: ShadowConfig
    public var background: BackgroundConfig
    /// When zoomed, the screen may grow over the padding until it fills the whole canvas.
    public var zoomFillsCanvas: Bool

    public init(
        aspectRatio: Double? = nil,
        paddingRatio: Double = 0.1,
        cornerRadius: Double = 16,
        inset: InsetConfig = InsetConfig(),
        shadow: ShadowConfig = ShadowConfig(),
        background: BackgroundConfig = BackgroundConfig(),
        zoomFillsCanvas: Bool = true
    ) {
        self.aspectRatio = aspectRatio
        self.paddingRatio = paddingRatio
        self.cornerRadius = cornerRadius
        self.inset = inset
        self.shadow = shadow
        self.background = background
        self.zoomFillsCanvas = zoomFillsCanvas
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StyleConfig()
        aspectRatio = c.value(.aspectRatio, default: d.aspectRatio)
        paddingRatio = c.value(.paddingRatio, default: d.paddingRatio)
        cornerRadius = c.value(.cornerRadius, default: d.cornerRadius)
        inset = c.value(.inset, default: d.inset)
        shadow = c.value(.shadow, default: d.shadow)
        background = c.value(.background, default: d.background)
        zoomFillsCanvas = c.value(.zoomFillsCanvas, default: d.zoomFillsCanvas)
    }

    /// The canvas long side in pixels; output resolution is chosen at export.
    public static let canvasLongSide: Double = 1920

    /// Canvas size: a fixed ratio, or (Auto) the recording plus its padding on every side.
    public func canvasSize(videoSize: Size2) -> Size2 {
        let ratio: Double
        if let aspectRatio {
            ratio = aspectRatio
        } else {
            let r = min(paddingRatio, 0.45)
            let w = videoSize.width, h = videoSize.height
            if w >= h {
                let height = h / (1 - 2 * r)
                ratio = (w + 2 * r * height) / height
            } else {
                let width = w / (1 - 2 * r)
                ratio = width / (h + 2 * r * width)
            }
        }
        let long = Self.canvasLongSide
        return ratio >= 1
            ? Size2(width: long, height: (long / ratio).rounded())
            : Size2(width: (long * ratio).rounded(), height: long)
    }
}

// MARK: - Cursor

public enum ClickEffect: String, Codable, CaseIterable, Sendable {
    case circle, ripple
}

public struct CursorConfig: Codable, Hashable, Sendable {
    /// "Cursor size", 16–128 (48 ≈ 1.5× the system cursor).
    public var size: Double
    public var hide: Bool
    /// "Hide cursor if not moving" (500–5000 ms), nil = off.
    public var hideNotMovingAfterMs: Double?
    /// "Loop cursor position" (1000–4000 ms before the end), nil = off.
    public var loopPositionBeforeEndMs: Double?
    public var clickEffect: ClickEffect?
    /// "Remove cursor shakes" threshold (100–2000), 0 = off.
    public var removeShakeThreshold: Double
    /// "Stop cursor movement at the end of the video" (0–5000 ms).
    public var stopMovementInLastPartMs: Double
    /// "Rotate cursor" (−180…180°).
    public var baseRotation: Double

    public init(
        size: Double = 48,
        hide: Bool = false,
        hideNotMovingAfterMs: Double? = nil,
        loopPositionBeforeEndMs: Double? = nil,
        clickEffect: ClickEffect? = nil,
        removeShakeThreshold: Double = 500,
        stopMovementInLastPartMs: Double = 0,
        baseRotation: Double = 0
    ) {
        self.size = size
        self.hide = hide
        self.hideNotMovingAfterMs = hideNotMovingAfterMs
        self.loopPositionBeforeEndMs = loopPositionBeforeEndMs
        self.clickEffect = clickEffect
        self.removeShakeThreshold = removeShakeThreshold
        self.stopMovementInLastPartMs = stopMovementInLastPartMs
        self.baseRotation = baseRotation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorConfig()
        size = c.value(.size, default: d.size)
        hide = c.value(.hide, default: d.hide)
        hideNotMovingAfterMs = c.value(.hideNotMovingAfterMs, default: d.hideNotMovingAfterMs)
        loopPositionBeforeEndMs = c.value(.loopPositionBeforeEndMs, default: d.loopPositionBeforeEndMs)
        clickEffect = c.value(.clickEffect, default: d.clickEffect)
        removeShakeThreshold = c.value(.removeShakeThreshold, default: d.removeShakeThreshold)
        stopMovementInLastPartMs = c.value(.stopMovementInLastPartMs, default: d.stopMovementInLastPartMs)
        baseRotation = c.value(.baseRotation, default: d.baseRotation)
    }

    /// Multiplier over the system cursor size (32 px reference).
    public var sizeMultiplier: Double { size / 32 }
}

// MARK: - Animations

public struct SpringPreset: Hashable, Sendable {
    public var name: String
    public var icon: String
    public var description: String?
    /// nil = no smoothing ("None").
    public var config: SpringConfig?

    public static let screen: [SpringPreset] = [
        SpringPreset(name: "Focused", icon: "target", description: "Animation stabilizes quickly making it easier to follow and read the content", config: SpringConfig(stiffness: 250, damping: 40, mass: 2.25)),
        SpringPreset(name: "Smooth", icon: "point.topleft.down.to.point.bottomright.curvepath", description: "Animation is more fluid. Great for more creative content not focused on reading", config: SpringConfig(stiffness: 170, damping: 50, mass: 3)),
    ]

    public static let cursor: [SpringPreset] = [
        SpringPreset(name: "Smooth", icon: "cursorarrow.click.2", config: SpringConfig(stiffness: 470, damping: 70, mass: 3)),
        SpringPreset(name: "Medium", icon: "cursorarrow.click", config: SpringConfig(stiffness: 340, damping: 60, mass: 3)),
        SpringPreset(name: "Rapid", icon: "cursorarrow.motionlines", config: SpringConfig(stiffness: 530, damping: 40, mass: 1)),
        SpringPreset(name: "None", icon: "cursorarrow", config: nil),
    ]
}

public struct AnimationConfig: Codable, Hashable, Sendable {
    public var screenSpring: SpringConfig
    /// Cursor smoothing; nil = none.
    public var mouseSpring: SpringConfig?
    /// "Start animation early" (applies to every zoom in the project).
    public var startsZoomEarly: Bool
    /// 0–1. Stored; motion blur is not rendered yet.
    public var motionBlurAmount: Double

    public init(
        screenSpring: SpringConfig = .screen,
        mouseSpring: SpringConfig? = SpringPreset.cursor[0].config,
        startsZoomEarly: Bool = false,
        motionBlurAmount: Double = 1
    ) {
        self.screenSpring = screenSpring
        self.mouseSpring = mouseSpring
        self.startsZoomEarly = startsZoomEarly
        self.motionBlurAmount = motionBlurAmount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnimationConfig()
        screenSpring = c.value(.screenSpring, default: d.screenSpring)
        mouseSpring = c.contains(.mouseSpring) ? c.value(.mouseSpring, default: d.mouseSpring) : d.mouseSpring
        startsZoomEarly = c.value(.startsZoomEarly, default: d.startsZoomEarly)
        motionBlurAmount = c.value(.motionBlurAmount, default: d.motionBlurAmount)
    }

    public var leadInMs: Double { startsZoomEarly ? 350 : 0 }
}
