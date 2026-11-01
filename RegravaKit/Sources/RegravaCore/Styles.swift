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

/// `background.gradient`: a linear gradient from `start` to `end` (fractions of the stage,
/// top-left origin) through colour stops at positions 0…1.
public struct BackgroundGradient: Codable, Hashable, Sendable {
    public struct Stop: Codable, Hashable, Sendable {
        public var color: RGBA
        /// Position along the gradient line, 0…1.
        public var at: Double

        public init(color: RGBA, at: Double) {
            self.color = color
            self.at = at
        }
    }

    public var start: Vec2
    public var end: Vec2
    public var stops: [Stop]

    public init(start: Vec2 = Vec2(0, 0), end: Vec2 = Vec2(1, 1), stops: [Stop]) {
        self.start = start
        self.end = end
        self.stops = stops
    }

    /// Colours spread evenly from the top-left to the bottom-right corner (the list form).
    public init(colors: [RGBA]) {
        self.init(stops: colors.enumerated().map { i, color in
            Stop(color: color, at: colors.count > 1 ? Double(i) / Double(colors.count - 1) : 0)
        })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = c.value(.start, default: Vec2(0, 0))
        end = c.value(.end, default: Vec2(1, 1))
        stops = c.value(.stops, default: [])
    }

    public static let `default` = BackgroundGradient(colors: [RGBA(hex: 0x4776E6), RGBA(hex: 0x8E54E9)])
}

public struct BackgroundConfig: Codable, Hashable, Sendable {
    /// Wallpaper shown by default.
    public static let defaultWallpaper = "macOS/san-francisco-dark.jpg"

    public var kind: BackgroundKind
    public var color: RGBA
    public var gradient: BackgroundGradient
    /// Wallpaper id: its path in the wallpaper library ("macOS/sonoma-light.jpg").
    public var systemName: String
    /// Image copied into the project folder.
    public var imageFileName: String?
    /// 0–100 px.
    public var blur: Double

    public init(
        kind: BackgroundKind = .wallpaper,
        color: RGBA = RGBA(hex: 0x4776E6),
        gradient: BackgroundGradient = .default,
        systemName: String = BackgroundConfig.defaultWallpaper,
        imageFileName: String? = nil,
        blur: Double = 0
    ) {
        self.kind = kind
        self.color = color
        self.gradient = gradient
        self.systemName = systemName
        self.imageFileName = imageFileName
        self.blur = blur
    }

    public init(
        kind: BackgroundKind = .wallpaper,
        color: RGBA = RGBA(hex: 0x4776E6),
        gradientStops: [RGBA],
        systemName: String = BackgroundConfig.defaultWallpaper,
        imageFileName: String? = nil,
        blur: Double = 0
    ) {
        self.init(kind: kind, color: color, gradient: BackgroundGradient(colors: gradientStops), systemName: systemName, imageFileName: imageFileName, blur: blur)
    }

    private enum LegacyKeys: String, CodingKey { case gradientStops, gradientFrom, gradientTo }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundConfig()
        kind = c.value(.kind, default: d.kind)
        color = c.value(.color, default: d.color)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        if let gradient = try? c.decodeIfPresent(BackgroundGradient.self, forKey: .gradient), !gradient.stops.isEmpty {
            self.gradient = gradient
        } else if let stops = try? legacy?.decodeIfPresent([RGBA].self, forKey: .gradientStops), stops.count >= 2 {
            gradient = BackgroundGradient(colors: stops)
        } else if let from = try? legacy?.decode(RGBA.self, forKey: .gradientFrom),
                  let to = try? legacy?.decode(RGBA.self, forKey: .gradientTo) {
            gradient = BackgroundGradient(colors: [from, to])
        } else {
            gradient = d.gradient
        }
        systemName = c.value(.systemName, default: d.systemName)
        imageFileName = c.value(.imageFileName, default: d.imageFileName)
        blur = c.value(.blur, default: d.blur)
    }

    /// The blur radius of `blur`, `stageWidth × blur / 100 × 0.05` stage pixels, for
    /// every kind of background.
    public func blurRadius(stageWidth: Double) -> Double {
        blur <= 0 ? 0 : stageWidth * (blur / 100) * 0.05
    }

    /// The stop colours; setting them spreads them evenly between the same start and end.
    public var gradientStops: [RGBA] {
        get { gradient.stops.map(\.color) }
        set {
            var spread = BackgroundGradient(colors: newValue)
            spread.start = gradient.start
            spread.end = gradient.end
            gradient = spread
        }
    }

    /// First stop; editing it rebuilds a 2-stop gradient.
    public var gradientFrom: RGBA {
        get { gradientStops.first ?? RGBA(hex: 0x4776E6) }
        set { gradientStops = [newValue, gradientTo] }
    }

    /// Last stop; editing it rebuilds a 2-stop gradient.
    public var gradientTo: RGBA {
        get { gradientStops.last ?? RGBA(hex: 0x8E54E9) }
        set { gradientStops = [gradientFrom, newValue] }
    }

    /// The 30 gradient presets.
    public static let gradientPresets: [[RGBA]] = [
        [0xF5F7FA, 0xC3CFE2], [0xA1C4FD, 0xC2E9FB], [0xFFECD2, 0xFCB69F], [0xE0C3FC, 0x8EC5FC],
        [0xA8EDEA, 0xFED6E3], [0xD4FC79, 0x96E6A1], [0xFA709A, 0xFEE140], [0xF6D365, 0xFDA085],
        [0xEE0979, 0xFF6A00], [0xF83600, 0xF9D423], [0x3A1C71, 0xD76D77, 0xFFAF7B],
        [0xFCC5E4, 0xFDA34B, 0xFF7882, 0xC8699E, 0x7046AA, 0x0C1DB8, 0x020F75],
        [0x4FACFE, 0x00F2FE], [0x1FA2FF, 0x12D8FA, 0xA6FFCB], [0x43CEA2, 0x185A9D], [0x11998E, 0x38EF7D],
        [0x134E5E, 0x71B280], [0x1A2980, 0x26D0CE], [0x4776E6, 0x8E54E9], [0xC33764, 0x1D2671],
        [0x30CFD0, 0x330867], [0xFC466B, 0x3F5EFB], [0x12C2E9, 0xC471ED, 0xF64F59], [0x00DBDE, 0xFC00FF],
        [0x0F2027, 0x203A43, 0x2C5364], [0x000428, 0x004E92], [0xC31432, 0x240B36],
        [0x03001E, 0x7303C0, 0xEC38BC, 0xFDEFF9], [0xBDC3C7, 0x2C3E50], [0x434343, 0x000000],
    ].map { $0.map { RGBA(hex: $0) } }
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
    /// "Avoid empty area": the resting screen covers the zoom area instead of fitting in it
    /// (`stage.avoidEmptyZoomArea`).
    public var avoidEmptyZoomArea = false
    /// Camera corner radius as a fraction of its shortest side (`cameraBorderRadiusRatio01`).
    public var cameraBorderRadiusRatio = 0.15

    public init(
        aspectRatio: Double? = nil,
        paddingRatio: Double = 0.1,
        cornerRadius: Double = 16,
        inset: InsetConfig = InsetConfig(),
        shadow: ShadowConfig = ShadowConfig(),
        background: BackgroundConfig = BackgroundConfig()) {
        self.aspectRatio = aspectRatio
        self.paddingRatio = paddingRatio
        self.cornerRadius = cornerRadius
        self.inset = inset
        self.shadow = shadow
        self.background = background
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
        avoidEmptyZoomArea = c.value(.avoidEmptyZoomArea, default: d.avoidEmptyZoomArea)
        cameraBorderRadiusRatio = c.value(.cameraBorderRadiusRatio, default: d.cameraBorderRadiusRatio)
    }

    /// The canvas long side in pixels; output resolution is chosen at export.
    public static let canvasLongSide: Double = 1920

    /// Canvas size without camera layouts: a fixed ratio, or (Auto) the recording grown by its
    /// padding (`sourceRect.padByRatio(p).aspectRatio`).
    public func canvasSize(videoSize: Size2) -> Size2 {
        Self.canvasSize(aspectRatio: aspectRatio ?? Rect2(size: videoSize).padByRatio(paddingRatio).aspectRatio)
    }

    /// Canvas of a stage aspect ratio, with `canvasLongSide` on its long side.
    public static func canvasSize(aspectRatio ratio: Double) -> Size2 {
        let long = canvasLongSide
        return ratio >= 1
            ? Size2(width: long, height: (long / ratio).rounded())
            : Size2(width: (long * ratio).rounded(), height: long)
    }
}

// MARK: - Cursor

/// `cursor.clickEffect`: `{type: "ripple", pullSize01?}` or `{type: "circle"}`.
public struct ClickEffect: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ripple, circle
    }

    public var type: Kind
    /// Ripple only: radius of the calm centre, in video widths (nil = 0.04).
    public var pullSize01: Double?

    public init(type: Kind, pullSize01: Double? = nil) {
        self.type = type
        self.pullSize01 = pullSize01
    }

    public static let circle = ClickEffect(type: .circle)
    public static let ripple = ClickEffect(type: .ripple)

    enum CodingKeys: String, CodingKey { case type, pullSize01 }

    public init(from decoder: Decoder) throws {
        // Projects written before the object form stored the type alone.
        if let single = try? decoder.singleValueContainer(), let kind = try? single.decode(Kind.self) {
            self.init(type: kind)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        self.init(type: kind, pullSize01: kind == .ripple ? try c.decodeIfPresent(Double.self, forKey: .pullSize01) : nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(pullSize01, forKey: .pullSize01)
    }
}

/// "Rotate while moving": Tilt leans with horizontal speed, Follow points along the travel.
public enum CursorRotationMode: String, Codable, CaseIterable, Sendable {
    case velocity
    case directional
}

/// `cursor.set`: the cursor style and the variant chosen per type.
public struct CursorSetChoice: Codable, Hashable, Sendable {
    public var id: String
    /// Cursor type → entry id ("pointer" → "pointer-3").
    public var variants: [String: String]

    public static let defaultID = "macos-tahoe"

    public init(id: String = CursorSetChoice.defaultID, variants: [String: String] = [:]) {
        self.id = id
        self.variants = variants
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: CursorSetChoice.defaultID)
        variants = c.value(.variants, default: [:])
    }
}

public struct CursorConfig: Codable, Hashable, Sendable {
    /// "Cursor size": how many source pixels tall the visible cursor is.
    public var size: Double
    /// "Cursor style".
    public var set: CursorSetChoice
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
    /// "Rotate while moving", added to `baseRotation`.
    public var rotationMode: CursorRotationMode
    /// "Tilt amount" (0…2) of the Tilt mode.
    public var rotateOnXMovementRatio: Double
    /// "Always use pointer cursor".
    public var alwaysUseDefault: Bool
    /// "Optimize cursor changes".
    public var optimizeOriginalTypes: Bool
    /// "Keep cursor in sync with hovers" (needs hover detection, not recorded yet).
    public var followRecordedPositionOnHover: Bool

    public init(
        size: Double = 48,
        hide: Bool = false,
        hideNotMovingAfterMs: Double? = nil,
        loopPositionBeforeEndMs: Double? = nil,
        clickEffect: ClickEffect? = nil,
        removeShakeThreshold: Double = 500,
        stopMovementInLastPartMs: Double = 0,
        baseRotation: Double = 0,
        rotationMode: CursorRotationMode = .velocity,
        rotateOnXMovementRatio: Double = 0.5,
        alwaysUseDefault: Bool = false,
        optimizeOriginalTypes: Bool = true,
        followRecordedPositionOnHover: Bool = true,
        set: CursorSetChoice = CursorSetChoice()
    ) {
        self.size = size
        self.set = set
        self.hide = hide
        self.hideNotMovingAfterMs = hideNotMovingAfterMs
        self.loopPositionBeforeEndMs = loopPositionBeforeEndMs
        self.clickEffect = clickEffect
        self.removeShakeThreshold = removeShakeThreshold
        self.stopMovementInLastPartMs = stopMovementInLastPartMs
        self.baseRotation = baseRotation
        self.rotationMode = rotationMode
        self.rotateOnXMovementRatio = rotateOnXMovementRatio
        self.alwaysUseDefault = alwaysUseDefault
        self.optimizeOriginalTypes = optimizeOriginalTypes
        self.followRecordedPositionOnHover = followRecordedPositionOnHover
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
        rotationMode = c.value(.rotationMode, default: d.rotationMode)
        rotateOnXMovementRatio = c.value(.rotateOnXMovementRatio, default: d.rotateOnXMovementRatio)
        alwaysUseDefault = c.value(.alwaysUseDefault, default: d.alwaysUseDefault)
        optimizeOriginalTypes = c.value(.optimizeOriginalTypes, default: d.optimizeOriginalTypes)
        followRecordedPositionOnHover = c.value(.followRecordedPositionOnHover, default: d.followRecordedPositionOnHover)
        set = c.value(.set, default: d.set)
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
        // New projects use the same default spring for both, so the cursor style starts with no
        // preset selected and no Reset.
        mouseSpring: SpringConfig? = .screen,
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
