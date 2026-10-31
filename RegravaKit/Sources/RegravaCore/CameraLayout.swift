import Foundation

// Camera layout resolvers.

public enum CameraLayoutType: String, Codable, CaseIterable, Sendable {
    case cameraOverlay = "camera-overlay"
    case splitScreen = "split-screen"
    case fullscreenCamera = "fullscreen-camera"
    case screenOnly = "screen-only"
    case cutoutCamera = "cutout-camera"
}

public enum SplitDirection: String, Codable, Sendable {
    case auto, horizontal, vertical
}

/// `cameraOverlay` options.
public struct OverlayLayoutOptions: Codable, Hashable, Sendable {
    public var position01 = Vec2(1, 1)
    public var sizeRatio01 = 0.5
    public var paddingRatio01 = 0.5
    public var aspectRatio = 1.0
    public var zoomedScale = 0.8

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlayLayoutOptions()
        position01 = c.value(.position01, default: d.position01)
        sizeRatio01 = c.value(.sizeRatio01, default: d.sizeRatio01)
        paddingRatio01 = c.value(.paddingRatio01, default: d.paddingRatio01)
        aspectRatio = c.value(.aspectRatio, default: d.aspectRatio)
        zoomedScale = c.value(.zoomedScale, default: d.zoomedScale)
    }
}

/// `splitScreen` options. `screenRatio01` nil = "Auto".
public struct SplitLayoutOptions: Codable, Hashable, Sendable {
    public var direction: SplitDirection = .auto
    public var flip = false
    public var screenRatio01: Double?
    public var enablePadding = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = c.value(.direction, default: .auto)
        flip = c.value(.flip, default: false)
        screenRatio01 = c.value(.screenRatio01, default: nil)
        enablePadding = c.value(.enablePadding, default: false)
    }
}

/// `cutoutCamera` options.
public struct CutoutLayoutOptions: Codable, Hashable, Sendable {
    public var positionX01 = 1.0
    public var sizeRatio01 = 0.5
    public var zoomedScale = 0.8
    public var aspectRatio: Double?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CutoutLayoutOptions()
        positionX01 = c.value(.positionX01, default: d.positionX01)
        sizeRatio01 = c.value(.sizeRatio01, default: d.sizeRatio01)
        zoomedScale = c.value(.zoomedScale, default: d.zoomedScale)
        aspectRatio = c.value(.aspectRatio, default: nil)
    }
}

/// `defaultLayout`: overlay, split screen or cutout.
public struct DefaultCameraLayout: Codable, Hashable, Sendable {
    public var type: CameraLayoutType = .cameraOverlay
    public var cameraOverlay = OverlayLayoutOptions()
    public var splitScreen = SplitLayoutOptions()
    public var cutoutCamera = CutoutLayoutOptions()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.value(.type, default: .cameraOverlay)
        cameraOverlay = c.value(.cameraOverlay, default: OverlayLayoutOptions())
        splitScreen = c.value(.splitScreen, default: SplitLayoutOptions())
        cutoutCamera = c.value(.cutoutCamera, default: CutoutLayoutOptions())
    }
}

/// A camera layout range. Overrides merge over the default layout.
public struct CameraLayoutRange: Codable, Hashable, Sendable, Identifiable {
    public static let minimumDurationMs = 500.0
    public static let initialDurationMs = 3000.0

    public var id: UUID
    public var startMs: Double
    public var endMs: Double
    public var type: CameraLayoutType
    public var isDisabled: Bool
    public var overlayPosition01: Vec2
    public var overlaySizeRatio01: Double?
    public var overlayZoomedScale: Double?
    public var overlayPaddingRatio01: Double?
    public var cutoutPositionX01: Double
    public var cutoutSizeRatio01: Double?
    public var cutoutZoomedScale: Double?

    public init(id: UUID = UUID(), startMs: Double, endMs: Double, type: CameraLayoutType = .cameraOverlay, isDisabled: Bool = false, overlayPosition01: Vec2 = Vec2(1, 1), cutoutPositionX01: Double = 1) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.type = type
        self.isDisabled = isDisabled
        self.overlayPosition01 = overlayPosition01
        self.cutoutPositionX01 = cutoutPositionX01
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        startMs = try c.decode(Double.self, forKey: .startMs)
        endMs = try c.decode(Double.self, forKey: .endMs)
        type = c.value(.type, default: .cameraOverlay)
        isDisabled = c.value(.isDisabled, default: false)
        overlayPosition01 = c.value(.overlayPosition01, default: Vec2(1, 1))
        overlaySizeRatio01 = c.value(.overlaySizeRatio01, default: nil)
        overlayZoomedScale = c.value(.overlayZoomedScale, default: nil)
        overlayPaddingRatio01 = c.value(.overlayPaddingRatio01, default: nil)
        cutoutPositionX01 = c.value(.cutoutPositionX01, default: 1)
        cutoutSizeRatio01 = c.value(.cutoutSizeRatio01, default: nil)
        cutoutZoomedScale = c.value(.cutoutZoomedScale, default: nil)
    }

    public var durationMs: Double { endMs - startMs }
    public var midMs: Double { startMs + durationMs / 2 }
    public func contains(_ t: Double) -> Bool { t >= startMs && t <= endMs }
}

/// `cameraConfig.background`: the cutout edge, shared by every cutout layout.
public struct CameraBackgroundConfig: Codable, Hashable, Sendable {
    /// "Edge softness": 1 keeps the matte as is, 0 makes the edge hard except in soft areas.
    public var edgeFalloff01 = 0.2
    /// "Edge inset": shrinks the matte by this many footage pixels.
    public var edgeInsetPx = 0.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edgeFalloff01 = c.value(.edgeFalloff01, default: 0.2)
        edgeInsetPx = c.value(.edgeInsetPx, default: 0)
    }
}

/// `cameraConfig`; image processing fields are kept for the panels.
public struct CameraConfig: Codable, Hashable, Sendable {
    public var hide = false
    public var mirror = false
    public var enableFaceTracking = false
    /// "Hide during silence" minimum silence (ms), nil = off.
    public var hideDuringSilenceMs: Double?
    public var sharpen01 = 0.0
    /// Film grain (`grain`); no control in 4.1.
    public var grain = 0.0
    /// Colour grade: the `.cube` asset name in the project's assets, nil = Original.
    public var lut: String?
    public var lutIntensity = 1.0
    /// Crop of the camera image (fractions), nil = whole image.
    public var crop01: Rect2?
    public var delayAdjustmentMs = 0.0
    public var background = CameraBackgroundConfig()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraConfig()
        hide = c.value(.hide, default: d.hide)
        mirror = c.value(.mirror, default: d.mirror)
        enableFaceTracking = c.value(.enableFaceTracking, default: d.enableFaceTracking)
        hideDuringSilenceMs = c.value(.hideDuringSilenceMs, default: nil)
        sharpen01 = c.value(.sharpen01, default: d.sharpen01)
        grain = c.value(.grain, default: d.grain)
        lut = c.value(.lut, default: nil)
        lutIntensity = c.value(.lutIntensity, default: d.lutIntensity)
        crop01 = c.value(.crop01, default: nil)
        delayAdjustmentMs = c.value(.delayAdjustmentMs, default: d.delayAdjustmentMs)
        background = c.value(.background, default: CameraBackgroundConfig())
    }
}

// MARK: - Resolvers

/// What every resolver needs (`stageLayoutInfo`).
public struct StageInfo: Hashable, Sendable {
    /// nil = "auto".
    public var aspectRatio: Double?
    public var sourceSize: Size2
    public var paddingRatio01: Double
    public var avoidEmptyZoomArea: Bool
    public var cameraSourceAspectRatio: Double?
}

/// Geometry of one layout in stage units (1080 tall).
public final class LayoutResolver: @unchecked Sendable {
    public enum Kind: Hashable, Sendable { case screenOnly, overlay, split, fullscreenCamera, cutout }

    public static let stageHeight = 1080.0

    public let kind: Kind
    public let info: StageInfo
    public let aspectRatio: Double
    public let stageRect: Rect2
    public let sourceRect: Rect2
    public let zoomArea: Rect2
    public let initialScreenRect: Rect2
    public let cameraRect: Rect2?
    public let zoomedCameraRect: Rect2?
    public let allowsCameraBorderRadius: Bool
    public let allowsScreenBorderRadius: Bool
    public let autoStageAspectRatio: Double
    /// Whether the fitted screen leaves empty bands in the zoom area ("Avoid empty area").
    public let hasUncoveredZoomArea: Bool
    private let split: SplitState?
    /// `LayoutMath.anchor` of the zoom area and camera: where zooms are anchored.
    private let zoomAnchor: Vec2
    private let makeVariant: (() -> LayoutResolver)?
    public private(set) lazy var zoomedVariant: LayoutResolver = makeVariant?() ?? self
    public var hideCameraVariant: LayoutResolver { zoomedVariant }

    struct SplitState {
        var screenSide: Side
        var cameraSide: Side
        var horizontal: Bool
    }

    enum Side { case left, right, top, bottom
        var opposite: Side { switch self { case .left: .right; case .right: .left; case .top: .bottom; case .bottom: .top } }
        var alignment: Vec2 { switch self { case .left: Vec2(0, 0.5); case .right: Vec2(1, 0.5); case .top: Vec2(0.5, 0); case .bottom: Vec2(0.5, 1) } }
    }

    private init(
        kind: Kind, info: StageInfo, aspectRatio: Double, autoStageAspectRatio: Double, zoomArea: Rect2,
        initialScreenRect: Rect2, cameraRect: Rect2?, zoomedCameraRect: Rect2?, allowsCameraBorderRadius: Bool,
        allowsScreenBorderRadius: Bool, hasUncoveredZoomArea: Bool, split: SplitState? = nil, makeVariant: (() -> LayoutResolver)? = nil
    ) {
        self.kind = kind
        self.info = info
        self.aspectRatio = aspectRatio
        self.autoStageAspectRatio = autoStageAspectRatio
        stageRect = Rect2.fromAspectRatio(aspectRatio, height: Self.stageHeight)
        sourceRect = Rect2(x: 0, y: 0, width: info.sourceSize.width, height: info.sourceSize.height)
        self.zoomArea = zoomArea
        self.initialScreenRect = initialScreenRect
        self.cameraRect = cameraRect
        self.zoomedCameraRect = zoomedCameraRect
        self.allowsCameraBorderRadius = allowsCameraBorderRadius
        self.allowsScreenBorderRadius = allowsScreenBorderRadius
        self.hasUncoveredZoomArea = hasUncoveredZoomArea
        self.split = split
        zoomAnchor = LayoutMath.anchor(zoomArea: zoomArea, camera: cameraRect)
        self.makeVariant = makeVariant
    }

    // MARK: Base and the types built on it

    private static func base(_ info: StageInfo) -> (auto: Double, ar: Double, stage: Rect2, source: Rect2, zoomArea: Rect2, screen: Rect2, uncovered: Bool) {
        let source = Rect2(x: 0, y: 0, width: info.sourceSize.width, height: info.sourceSize.height)
        let auto = source.padByRatio(info.paddingRatio01).aspectRatio
        let ar = info.aspectRatio ?? auto
        let stage = Rect2.fromAspectRatio(ar, height: stageHeight)
        let zoomArea = stage.padByRatio(-info.paddingRatio01)
        let fitted = source.fitInside(zoomArea, allowEnlarge: true)
        let screen = info.avoidEmptyZoomArea ? source.cover(zoomArea) : fitted
        let uncovered = !(zoomArea.width <= fitted.width && zoomArea.height <= fitted.height)
        return (auto, ar, stage, source, zoomArea, screen, uncovered)
    }

    public static func screenOnly(_ info: StageInfo) -> LayoutResolver {
        let b = base(info)
        return LayoutResolver(kind: .screenOnly, info: info, aspectRatio: b.ar, autoStageAspectRatio: b.auto, zoomArea: b.zoomArea,
                              initialScreenRect: b.screen, cameraRect: nil, zoomedCameraRect: nil, allowsCameraBorderRadius: true,
                              allowsScreenBorderRadius: true, hasUncoveredZoomArea: b.uncovered)
    }

    /// Camera-overlay.
    public static func overlay(_ options: OverlayLayoutOptions, _ info: StageInfo) -> LayoutResolver {
        let b = base(info)
        let p = info.paddingRatio01
        let resolvedPad = p < 0.1
            ? LayoutMath.mapRange(options.paddingRatio01, 0, 1, 0.025, 0.1)
            : LayoutMath.mapRange(options.paddingRatio01, 0, 1, 0.025, p)
        func cameraRect(scale: Double, padMultiplier: Double) -> Rect2 {
            let bounds = b.stage.padByRatio(-resolvedPad * padMultiplier)
            let side = b.stage.shortestSide * options.sizeRatio01 * scale
            return Rect2.fromAspectRatio(options.aspectRatio, width: side)
                .fitInside(Rect2(x: 0, y: 0, width: side, height: side))
                .align(bounds, options.position01)
        }
        return LayoutResolver(kind: .overlay, info: info, aspectRatio: b.ar, autoStageAspectRatio: b.auto, zoomArea: b.zoomArea,
                              initialScreenRect: b.screen, cameraRect: cameraRect(scale: 1, padMultiplier: 1),
                              zoomedCameraRect: cameraRect(scale: options.zoomedScale, padMultiplier: 0.5),
                              allowsCameraBorderRadius: true, allowsScreenBorderRadius: true, hasUncoveredZoomArea: b.uncovered)
    }

    /// Cutout-camera: bottom-aligned, padded horizontally only.
    public static func cutout(_ options: CutoutLayoutOptions, _ info: StageInfo) -> LayoutResolver {
        let b = base(info)
        let cameraAR = options.aspectRatio ?? info.cameraSourceAspectRatio ?? 1
        func cameraRect(scale: Double) -> Rect2 {
            let side = b.stage.shortestSide * options.sizeRatio01 * scale
            let rect = Rect2.fromAspectRatio(cameraAR, width: side).fitInside(Rect2(x: 0, y: 0, width: side, height: side))
            let padded = b.stage.padByRatio(-info.paddingRatio01)
            let box = Rect2(x: padded.x, y: b.stage.y, width: padded.width, height: b.stage.height)
            return rect.align(box, Vec2(options.positionX01, 1))
        }
        return LayoutResolver(kind: .cutout, info: info, aspectRatio: b.ar, autoStageAspectRatio: b.auto, zoomArea: b.zoomArea,
                              initialScreenRect: b.screen, cameraRect: cameraRect(scale: 1), zoomedCameraRect: cameraRect(scale: options.zoomedScale),
                              allowsCameraBorderRadius: false, allowsScreenBorderRadius: true, hasUncoveredZoomArea: b.uncovered)
    }

    /// Fullscreen-camera: the camera fills the stage.
    public static func fullscreenCamera(_ info: StageInfo) -> LayoutResolver {
        let b = base(info)
        return LayoutResolver(kind: .fullscreenCamera, info: info, aspectRatio: b.ar, autoStageAspectRatio: b.auto, zoomArea: b.zoomArea,
                              initialScreenRect: b.screen, cameraRect: b.stage, zoomedCameraRect: b.stage,
                              allowsCameraBorderRadius: false, allowsScreenBorderRadius: false, hasUncoveredZoomArea: b.uncovered)
    }

    // MARK: Split screen

    /// Auto stage aspect for split screen.
    static func splitAutoAspect(paddingRatio pR: Double, screenAspect ar: Double) -> Double {
        let p = pR * 1080
        let h = 1080 - 2 * p
        let cameraWidthOverHeight = (1920 - 3 * p - ar * h) / h
        if cameraWidthOverHeight >= 0.4 && cameraWidthOverHeight <= 16.0 / 9 { return 16.0 / 9 }
        let p2 = pR * 1000
        return clamp((3 * p2 + ar * 1000 + 0.5625 * 1000) / (2 * p2 + 1000), 1, 2.4)
    }

    public static func split(_ options: SplitLayoutOptions, _ info: StageInfo) -> LayoutResolver {
        let source = Rect2(x: 0, y: 0, width: info.sourceSize.width, height: info.sourceSize.height)
        let screenAR = source.aspectRatio
        let pR = options.enablePadding ? info.paddingRatio01 : 0
        let auto = splitAutoAspect(paddingRatio: pR, screenAspect: screenAR)
        let ar = info.aspectRatio ?? auto
        let stage = Rect2.fromAspectRatio(ar, height: stageHeight)
        let horizontal: Bool = switch options.direction {
        case .auto: stage.aspectRatio >= 1
        case .horizontal: true
        case .vertical: false
        }
        let screenSide: Side = horizontal ? (options.flip ? .right : .left) : (options.flip ? .bottom : .top)
        let cameraSide = screenSide.opposite
        let area = stage.padByRatio(-pR)
        let gap = area.x
        func alignTo(_ r: Rect2, _ side: Side) -> Rect2 { r.align(area, side.alignment) }
        func avail(_ r: Rect2? = nil) -> Double? {
            let v = (horizontal ? area.width : area.height) - gap - (r.map { horizontal ? $0.width : $0.height } ?? 0)
            return v < 0 ? nil : v
        }
        func cameraRectFor(_ side: Side, _ length: Double?) -> Rect2 {
            let sideways = side == .left || side == .right
            let ok = length.map { sideways ? $0 / area.height > 0.4 : area.width / $0 < 2.5 } ?? false
            if !ok {
                return sideways ? alignTo(Rect2.fromAspectRatio(0.5, height: area.height), side)
                    : alignTo(Rect2.fromAspectRatio(2.5, width: area.width), side)
            }
            return sideways ? alignTo(Rect2(x: 0, y: 0, width: length!, height: area.height), side)
                : alignTo(Rect2(x: 0, y: 0, width: area.width, height: length!), side)
        }
        func zoomAreaFor(_ camera: Rect2) -> Rect2 {
            let l = avail(camera) ?? 0
            return alignTo(horizontal ? Rect2(x: 0, y: 0, width: l, height: area.height) : Rect2(x: 0, y: 0, width: area.width, height: l), screenSide)
        }
        func explicit(_ r: Double) -> (screen: Rect2, camera: Rect2, zone: Rect2) {
            let camera = cameraRectFor(cameraSide, avail().map { $0 * (1 - r) })
            let zone = zoomAreaFor(camera)
            return (Rect2.fromAspectRatio(screenAR, width: 1).cover(zone), camera, zone)
        }
        func automatic() -> (screen: Rect2, camera: Rect2, zone: Rect2) {
            if !horizontal { return explicit(0.5) }
            let s0 = alignTo(Rect2.fromAspectRatio(screenAR, height: area.height), screenSide)
            let camera = cameraRectFor(cameraSide, avail(s0))
            let zone = zoomAreaFor(camera)
            return (s0.cover(zone), camera, zone)
        }
        var g = options.screenRatio01.map(explicit) ?? automatic()
        // Let the screen letterbox by up to 10% across the split instead of overflowing.
        let over = horizontal ? g.screen.width - g.zone.width : g.screen.height - g.zone.height
        if over > 0.5 {
            let k = gap == 0 ? 1.0 : 0.9
            let screen = horizontal
                ? Rect2.fromAspectRatio(screenAR, height: max(g.zone.width / screenAR, g.zone.height * k))
                : Rect2.fromAspectRatio(screenAR, width: max(g.zone.height * screenAR, g.zone.width * k))
            g.screen = screen.align(g.zone, Vec2(0.5, 0.5))
        }
        let state = SplitState(screenSide: screenSide, cameraSide: cameraSide, horizontal: horizontal)
        let camera = g.camera
        let variant: () -> LayoutResolver = {
            // Zoomed / hidden camera: an overlay in the camera's corner.
            var overlay = OverlayLayoutOptions()
            overlay.aspectRatio = clamp(camera.aspectRatio, 9.0 / 16, 16.0 / 9)
            overlay.paddingRatio01 = 0.5
            overlay.sizeRatio01 = 0.5
            overlay.zoomedScale = 1
            overlay.position01 = switch cameraSide {
            case .left: Vec2(0, 1)
            case .right: Vec2(1, 1)
            case .top: Vec2(1, 0)
            case .bottom: Vec2(1, 1)
            }
            var variantInfo = info
            variantInfo.aspectRatio = ar
            variantInfo.paddingRatio01 = pR
            return LayoutResolver.overlay(overlay, variantInfo)
        }
        let resolver = LayoutResolver(kind: .split, info: info, aspectRatio: ar, autoStageAspectRatio: auto, zoomArea: g.zone,
                                      initialScreenRect: g.screen, cameraRect: g.camera, zoomedCameraRect: nil,
                                      allowsCameraBorderRadius: pR > 0, allowsScreenBorderRadius: pR > 0, hasUncoveredZoomArea: false,
                                      split: state, makeVariant: variant)
        return resolver
    }

    /// Camera rect while a zoom moves the screen; split uses its overlay variant's.
    public var effectiveZoomedCameraRect: Rect2? {
        kind == .split ? zoomedVariant.cameraRect : zoomedCameraRect
    }

    // MARK: Screen rect

    /// `getScreenRect(focus, level)`: the screen zoomed on `focus01`, anchored where the camera
    /// does not cover the zoom area. At rest, split screen pins the focus to the edge it rests
    /// against. `bounds01` are the cursor bounds of the resting focus (a point at `focus01` when absent).
    public func screenRect(focus01: Vec2, bounds01: Rect2? = nil, level: Double) -> Rect2 {
        var focus = focus01
        if let split, level <= 1 {
            let side = restingSide(split, cursorBounds01: bounds01 ?? Rect2(x: focus01.x, y: focus01.y, width: 0, height: 0))
            focus = switch side {
            case .left: Vec2(0, focus.y)
            case .right: Vec2(1, focus.y)
            case .top: Vec2(focus.x, 0)
            case .bottom: Vec2(focus.x, 1)
            }
        }
        return initialScreenRect.zoom(level, origin01: focus, area: zoomArea, anchor: zoomAnchor)
    }

    /// Edge the overflowing split screen rests against: its own, or the camera's when the cursor
    /// bounds come within 12.5% of the camera.
    private func restingSide(_ split: SplitState, cursorBounds01 b: Rect2) -> Side {
        guard let camera = cameraRect else { return split.screenSide }
        let opposite = split.screenSide.opposite
        let s = initialScreenRect.align(zoomArea, split.screenSide.alignment)
        let edge: Vec2 = switch opposite {
        case .left, .top: Vec2(b.x, b.y)
        case .right: Vec2(b.endX, b.y)
        case .bottom: Vec2(b.x, b.endY)
        }
        let point = Vec2(s.x + edge.x * s.width, s.y + edge.y * s.height)
        let distance: Double = switch opposite {
        case .right: camera.x - point.x
        case .left: point.x - camera.endX
        case .bottom: camera.y - point.y
        case .top: point.y - camera.endY
        }
        let size = (opposite == .left || opposite == .right) ? s.width : s.height
        return distance < 0.125 * size ? opposite : split.screenSide
    }

    /// Part of the source visible at `level` (`getVisibleSourcePart`). The source is scaled in its
    /// own pixels and compared with the 1080-tall stage.
    public func visibleSourcePart(level: Double) -> Size2 {
        Self.visibleSourcePart(stage: stageRect.size, source: sourceRect.size, level: level)
    }

    /// `getVisibleSourcePart` for a source measured in `source` units.
    public static func visibleSourcePart(stage: Size2, source: Size2, level: Double) -> Size2 {
        let w = source.width * level, h = source.height * level
        return Size2(
            width: min(1, stage.width / max(w, 0.0001)) * source.width,
            height: min(1, stage.height / max(h, 0.0001)) * source.height
        )
    }
}

// MARK: - Layouts over time

public extension Project {
    var stageInfo: StageInfo {
        StageInfo(
            aspectRatio: style.aspectRatio,
            // With a device frame the layout fits the whole device body (`recordingBodySize`).
            // The cropped recording (`recordingBodySize`).
            sourceSize: activeDeviceFrame.map { Size2(width: $0.device.width, height: $0.device.height) } ?? croppedVideoSize,
            paddingRatio01: style.paddingRatio,
            avoidEmptyZoomArea: style.avoidEmptyZoomArea,
            cameraSourceAspectRatio: cameraSourceAspectRatio
        )
    }

    /// Camera image aspect after `crop01`.
    var cameraSourceAspectRatio: Double? {
        guard let size = recording.cameraSize, size.height > 0 else { return nil }
        let crop = camera.crop01 ?? Rect2(x: 0, y: 0, width: 1, height: 1)
        return size.width / size.height * (crop.width / max(crop.height, 0.0001))
    }

    /// The project's own layout when no range applies. Without camera footage it is screen-only.
    var defaultLayoutResolver: LayoutResolver {
        let info = stageInfo
        guard recording.hasCamera else { return .screenOnly(info) }
        switch defaultLayout.type {
        case .splitScreen: return .split(defaultLayout.splitScreen, info)
        case .cutoutCamera: return .cutout(defaultLayout.cutoutCamera, info)
        default: return .overlay(defaultLayout.cameraOverlay, info)
        }
    }

    /// The screen alone on the default layout's stage, fitted whole ("Avoid empty area" off):
    /// the stage shown while placing an item or editing a mask.
    var plainLayoutResolver: LayoutResolver {
        var info = stageInfo
        info.aspectRatio = defaultLayoutResolver.aspectRatio
        info.avoidEmptyZoomArea = false
        return .screenOnly(info)
    }

    /// Stage aspect: the style's, or the default layout's automatic one.
    var stageAspectRatio: Double { style.aspectRatio ?? defaultLayoutResolver.autoStageAspectRatio }

    /// Resolver of a range: its type with the default options merged with its
    /// overrides. Ranges use the already resolved stage aspect.
    func resolver(for range: CameraLayoutRange) -> LayoutResolver {
        var info = stageInfo
        info.aspectRatio = stageAspectRatio
        switch range.type {
        case .cameraOverlay:
            var options = defaultLayout.cameraOverlay
            options.position01 = range.overlayPosition01
            if let v = range.overlaySizeRatio01 { options.sizeRatio01 = v }
            if let v = range.overlayZoomedScale { options.zoomedScale = v }
            if let v = range.overlayPaddingRatio01 { options.paddingRatio01 = v }
            return .overlay(options, info)
        case .splitScreen:
            return .split(defaultLayout.splitScreen, info)
        case .cutoutCamera:
            var options = defaultLayout.cutoutCamera
            options.positionX01 = range.cutoutPositionX01
            if let v = range.cutoutSizeRatio01 { options.sizeRatio01 = v }
            if let v = range.cutoutZoomedScale { options.zoomedScale = v }
            return .cutout(options, info)
        case .fullscreenCamera:
            return .fullscreenCamera(info)
        case .screenOnly:
            return .screenOnly(info)
        }
    }

    /// `isCutoutLayoutUsed`: then every camera frame is matted.
    var isCutoutLayoutUsed: Bool {
        recording.hasCamera && !camera.hide
            && (defaultLayout.type == .cutoutCamera || cameraLayouts.contains { !$0.isDisabled && $0.type == .cutoutCamera })
    }

    var sortedCameraLayouts: [CameraLayoutRange] { cameraLayouts.sorted { $0.startMs < $1.startMs } }

    /// `isEqualToDefaultLayout`: same type as the default layout and, for overlay and cutout,
    /// overrides that change nothing. Such ranges get the disabled look.
    func isEqualToDefaultLayout(_ range: CameraLayoutRange) -> Bool {
        guard range.type == defaultLayout.type else { return false }
        switch range.type {
        case .cameraOverlay:
            var merged = defaultLayout.cameraOverlay
            merged.position01 = range.overlayPosition01
            if let v = range.overlaySizeRatio01 { merged.sizeRatio01 = v }
            if let v = range.overlayZoomedScale { merged.zoomedScale = v }
            if let v = range.overlayPaddingRatio01 { merged.paddingRatio01 = v }
            return merged == defaultLayout.cameraOverlay
        case .cutoutCamera:
            var merged = defaultLayout.cutoutCamera
            merged.positionX01 = range.cutoutPositionX01
            if let v = range.cutoutSizeRatio01 { merged.sizeRatio01 = v }
            if let v = range.cutoutZoomedScale { merged.zoomedScale = v }
            return merged == defaultLayout.cutoutCamera
        default:
            return true
        }
    }

    /// `getFreeRangeStartingAt`: `[t, min(next start, t + duration)]`, nil when `t` is inside a
    /// range or the gap is shorter than the minimum.
    func freeLayoutRange(startingAt t: Double, durationMs: Double = CameraLayoutRange.initialDurationMs) -> (start: Double, end: Double)? {
        let sorted = sortedCameraLayouts
        if sorted.contains(where: { $0.startMs < t && $0.endMs > t }) { return nil }
        let next = sorted.first { $0.startMs > t }?.startMs ?? recording.durationMs
        let end = min(next, t + durationMs)
        return end - t < CameraLayoutRange.minimumDurationMs ? nil : (t, end)
    }
}

/// Picks the resolvers for the screen and for the camera at a source time.
public struct LayoutTimeline: Sendable {
    let ranges: [CameraLayoutRange]
    let resolvers: [UUID: LayoutResolver]
    public let defaultResolver: LayoutResolver
    /// Largest `endMs` of `ranges` up to each index.
    private let maxEndThrough: [Double]

    public init(project: Project) {
        defaultResolver = project.defaultLayoutResolver
        let usable = project.recording.hasCamera ? project.cameraLayouts.sorted { $0.startMs < $1.startMs } : []
        ranges = usable
        var maxEnd: [Double] = []
        for range in usable { maxEnd.append(max(maxEnd.last ?? -.infinity, range.endMs)) }
        maxEndThrough = maxEnd
        var resolvers: [UUID: LayoutResolver] = [:]
        for range in usable { resolvers[range.id] = project.resolver(for: range) }
        self.resolvers = resolvers
    }

    /// Enabled range at `t` (`findAt`, both ends inclusive).
    public func activeRange(at t: Double) -> CameraLayoutRange? {
        // The last range containing `t`: among those starting at or before it, back to the
        // first whose predecessors all end before it.
        guard var i = lastSearch(count: ranges.count, while: { ranges[$0].startMs <= t }) else { return nil }
        while i >= 0 && t <= maxEndThrough[i] {
            if ranges[i].contains(t) { return ranges[i].isDisabled ? nil : ranges[i] }
            i -= 1
        }
        return nil
    }

    private func resolver(at t: Double) -> LayoutResolver {
        activeRange(at: t).flatMap { resolvers[$0.id] } ?? defaultResolver
    }

    /// The screen's layout: a fullscreen-camera range keeps the neighbouring layout's screen
    /// (the previous one in its first half, the next in its second half).
    public func screenResolver(at t: Double) -> LayoutResolver {
        guard let range = activeRange(at: t) else { return defaultResolver }
        if range.type == .fullscreenCamera {
            return t < range.midMs ? resolver(at: range.startMs - 1) : resolver(at: range.endMs + 1)
        }
        return resolvers[range.id] ?? defaultResolver
    }

    /// The camera's layout: a screen-only range keeps the neighbouring layout's camera.
    public func cameraResolver(at t: Double) -> LayoutResolver {
        guard let range = activeRange(at: t) else { return defaultResolver }
        if range.type == .screenOnly {
            return t < range.midMs ? resolver(at: range.startMs - 1) : resolver(at: range.endMs + 1)
        }
        return resolvers[range.id] ?? defaultResolver
    }

    /// Camera hidden at `t` (hiding during silence is not available).
    public func isCameraHidden(at t: Double) -> Bool {
        guard let range = activeRange(at: t) else { return false }
        if range.type == .fullscreenCamera { return false }
        return range.type == .screenOnly
    }
}
