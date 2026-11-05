import Foundation

/// Where things sit on the output canvas. Layouts work in stage units (1080 tall); the canvas
/// is the stage scaled to `canvas.height / 1080`.
public struct CanvasLayout: Hashable, Sendable {
    public let canvas: Rect2
    /// Stage units to canvas pixels.
    public let scale: Double
    /// Screen rectangle of the default layout when not zoomed, in canvas pixels.
    public let restScreen: Rect2
    public let videoSize: Size2

    public init(project: Project) {
        let resolver = project.defaultLayoutResolver
        canvas = Rect2(size: project.canvasSize)
        scale = canvas.height / LayoutResolver.stageHeight
        videoSize = project.recording.videoSize
        restScreen = Self.scaled(resolver.initialScreenRect, scale)
    }

    private init(canvas: Rect2, scale: Double, restScreen: Rect2, videoSize: Size2) {
        self.canvas = canvas
        self.scale = scale
        self.restScreen = restScreen
        self.videoSize = videoSize
    }

    /// The same layout on a canvas `k` times larger: everything in canvas pixels grows by `k`.
    public func scaled(by k: Double) -> CanvasLayout { scaled(x: k, y: k) }

    /// The same layout on a canvas `kx` times wider and `ky` times taller: placements grow by
    /// each axis's factor, lengths (stage units to pixels) by the height's.
    public func scaled(x kx: Double, y ky: Double) -> CanvasLayout {
        CanvasLayout(canvas: Self.scaled(canvas, kx, ky), scale: scale * ky, restScreen: Self.scaled(restScreen, kx, ky), videoSize: videoSize)
    }

    static func scaled(_ r: Rect2, _ k: Double) -> Rect2 { scaled(r, k, k) }

    static func scaled(_ r: Rect2, _ kx: Double, _ ky: Double) -> Rect2 {
        Rect2(x: r.x * kx, y: r.y * ky, width: r.width * kx, height: r.height * ky)
    }

    /// Stage units to canvas pixels.
    public func toCanvas(_ r: Rect2) -> Rect2 { Self.scaled(r, scale) }

    /// Maps a point in video pixels to canvas pixels for a given screen placement.
    public func canvasPoint(videoPoint: Vec2, screenRect: Rect2) -> Vec2 {
        Vec2(
            screenRect.x + videoPoint.x / videoSize.width * screenRect.width,
            screenRect.y + videoPoint.y / videoSize.height * screenRect.height
        )
    }
}

/// Everything the renderer needs for one instant.
public struct CameraFrame: Hashable, Sendable {
    public var timeMs: Double
    /// Where the recorded screen is drawn on the canvas.
    public var screenRect: Rect2
    /// Smoothed cursor position in video pixels.
    public var cursor: Vec2?
    /// 1 = visible; fades to 0 with "Hide cursor if not moving".
    public var cursorOpacity: Double = 1
    /// Cursor image name ("pointer", "pointinghand", "ibeamstroke"… or "custom-N").
    public var cursorName: String = CursorTypes.defaultName
    /// Spring-animated press scale: 0.9 while pressed.
    public var cursorScale: Double = 1
    /// Sprung cursor rotation in radians (base plus motion rotation), positive clockwise.
    public var cursorRotationRad: Double = 0
    /// Sprung blur of a fading cursor, in stage units (10 when hidden).
    public var cursorFadeBlurRadius: Double = 0
    /// Inside an instant zoom's snap window (motion blur is off there).
    public var isInstantSnap = false
    /// The same values one playback frame earlier, for motion blur.
    public var previousScreenRect: Rect2?
    public var previousCursor: Vec2?
    public var previousCursorScale: Double = 1
    public var previousCursorRotationRad: Double = 0
    /// Webcam placement one playback frame earlier, for its motion blur.
    public var previousCameraRect: Rect2?
    /// Mask applied to the recording.
    public var mask: MaskFrame = .none
    /// Webcam placement in canvas pixels; nil without camera footage.
    public var cameraRect: Rect2?
    public var cameraOpacity: Double = 0
    /// Point of the (cropped, mirrored) camera image kept at the frame centre (face tracking).
    public var cameraFocal01 = Vec2(0.5, 0.5)
    /// 1 in a cutout layout, sprung with the camera (`cutout01`): drives the background reveal
    /// (1 − cutout01) and the silhouette shadow.
    public var cameraCutout01 = 0.0
    /// Drawn corner radius in canvas pixels.
    public var cameraCornerRadius: Double = 0
    /// Camera width over its layout's resting width: scales its shadow.
    public var cameraSizeFactor: Double = 1
    /// Resting screen width of the active layout in canvas pixels
    /// (`referenceWidth`): the screen's zoom factor for its shadow blur.
    public var screenReferenceWidth: Double = 0
    /// The active layout allows screen corners (`allowsScreenBorderRadius`).
    public var allowsScreenBorderRadius = true
    /// The stage is not fully covered by the resting screen, so the inset shows.
    public var isBackgroundVisible = true
    /// The glass loupe, sprung; nil when it shows nothing.
    public var loupe: LoupeFrame?
    /// Presses the click effect draws (at most three), oldest first.
    public var clicks: [CursorClick] = []
    /// Where the background is laid out (canvas pixels), sprung; nil = the canvas.
    public var backgroundRect: Rect2?
    /// The background's blur and the loupe frost's extra blur, in stage pixels, sprung; nil =
    /// from the style alone.
    public var backgroundBlurRadius: Double?
    public var frostBlurRadius: Double?
}

extension CameraFrame {
    /// The frame on a canvas `k` times larger: every canvas-pixel placement grows by `k`;
    /// video pixels, stage units and fractions stay as they are.
    public func scaled(by k: Double) -> CameraFrame { scaled(x: k, y: k) }

    /// The frame on a canvas `kx` times wider and `ky` times taller: placements grow by each
    /// axis's factor, widths by `kx` and lengths by the height's.
    public func scaled(x kx: Double, y ky: Double) -> CameraFrame {
        guard kx != 1 || ky != 1 else { return self }
        func r(_ rect: Rect2) -> Rect2 { CanvasLayout.scaled(rect, kx, ky) }
        var f = self
        f.screenRect = r(screenRect)
        f.previousScreenRect = previousScreenRect.map(r)
        f.cameraRect = cameraRect.map(r)
        f.previousCameraRect = previousCameraRect.map(r)
        f.cameraCornerRadius = cameraCornerRadius * ky
        f.screenReferenceWidth = screenReferenceWidth * kx
        f.backgroundRect = backgroundRect.map(r)
        return f
    }
}

/// Precomputed, deterministic camera and cursor animation for a whole project.
///
/// Springs are stateful, so the track simulates the full timeline once, advancing them one
/// project frame at a time. the simulation runs in playback time (clips sped up, slowed down
/// or cut) while zooms, mouse and keyboard data are looked up in source time (`Dd.timeMs =
/// resolver.playbackToSourceTime(playbackMs)`).
public final class CameraTrack: @unchecked Sendable {
    public let layout: CanvasLayout
    /// Playback duration.
    public let durationMs: Double
    public let sampleIntervalMs: Double
    public let resolver: TimeResolver
    /// Frame rate of the editor's playback: springs, motion blur and the previous frame follow
    /// the rate frames are produced at, this while editing and the chosen rate on export.
    public static let previewFps = 60.0

    /// Scale of the cursor while a button is held.
    public static let pressedCursorScale = 0.9

    private let samples: [CameraFrame]
    /// Presses of the drawn cursor's events.
    private let clicks: [MouseEvent]
    private let typeEvents: [MouseEvent]
    /// Image names of `typeEvents`, index for index.
    private let typeEventNames: [String]
    private let cursorConfig: CursorConfig
    private let planner: CameraPlanner
    /// The screen-only layout of the plain stage.
    private let plainResolver: LayoutResolver

    public init(project fullProject: Project, faces: CameraFaces? = nil, silence: [SilenceChunk] = [], hovers: CursorHovers? = nil, fps: Double = CameraTrack.previewFps) {
        // Everything below works in the crop's space.
        let project = fullProject.screenCropSpace
        let layout = CanvasLayout(project: project)
        self.layout = layout
        let timeline = LayoutTimeline(project: project)
        let resolver = project.resolver
        self.resolver = resolver
        durationMs = max(resolver.playbackDurationMs, 0)
        sampleIntervalMs = 1000 / max(fps, 1)

        let sorted = project.mouseEvents.sorted { $0.timeMs < $1.timeMs }
        let cleaned = MouseProcessing.removeShakes(sorted, threshold: project.cursor.removeShakeThreshold)
        cursorConfig = project.cursor
        let typeEvents = CursorTypes.typeEvents(cleaned, config: project.cursor)
        self.typeEvents = typeEvents
        let typeEventNames = project.cursor.alwaysUseDefault ? [] : CursorTypes.assetNames(of: typeEvents)
        self.typeEventNames = typeEventNames
        let imageChanges = CursorTypes.imageChangeTimes(typeEvents, names: typeEventNames, config: project.cursor)
        let pathEvents = Self.cursorPathEvents(events: cleaned, resolver: resolver, config: project.cursor)
        clicks = pathEvents.filter { $0.kind == .down }
        let hoverTimes = project.cursorHoverTimes(hovers)

        let planner = CameraPlanner(project: project, timeline: timeline, cleaned: cleaned, pathEvents: pathEvents, silence: silence)
        self.planner = planner
        plainResolver = project.plainLayoutResolver

        let cursorPlan = CursorPathCache.shared.plan(for: CursorPlan.Inputs(
            pathEvents: pathEvents,
            cleanedEvents: cleaned,
            imageChangesMs: imageChanges,
            hoverTimesMs: hoverTimes,
            slices: project.slices,
            spring: project.animation.mouseSpring,
            pointPixelScale: project.recording.pointPixelScale,
            rotationMode: project.cursor.rotationMode,
            rotateOnXMovementRatio: project.cursor.rotateOnXMovementRatio
        ))

        var screen = SpringRect(timeline.defaultResolver.initialScreenRect)
        var cameraRect = SpringRect(Rect2(x: 0, y: 0, width: 0, height: 0))
        var cameraOpacity = SpringValue(0)
        var cameraRadius = SpringValue(0)
        var cameraReference = SpringValue(1)
        let hasCamera = project.recording.hasCamera && !project.camera.hide
        let samplesFor200Ms = Int((200 / sampleIntervalMs).rounded(.up))
        var lastHiddenIndex: Int?
        var maskAnimator = MaskAnimator(masks: project.masks, recordingSize: project.recording.videoSize)
        var press = SpringValue(1)
        var opacity = SpringValue(1)
        var rotation = SpringValue(0)
        var fadeBlur = SpringValue(0)
        let rotationSpring = CursorRotation.spring(for: project.cursor.rotationMode)
        let baseRotationRad = project.cursor.baseRotation * .pi / 180
        // Face tracking: the focal point always uses its own spring.
        let confidentFaces = project.camera.enableFaceTracking ? FaceTracking.confident(faces) : nil
        var focalX = SpringValue(0.5), focalY = SpringValue(0.5)
        var cutout = SpringValue(0)
        var loupe = LoupeSpring(.none)
        var backdrop = BackdropSpring()
        // The canvas in stage units.
        let stage = Rect2(x: 0, y: 0, width: layout.canvas.width / layout.scale, height: layout.canvas.height / layout.scale)
        let buttonEvents = pathEvents.filter(\.isClick)
        var frames: [CameraFrame] = []
        let count = Int((durationMs / sampleIntervalMs).rounded(.up)) + 2
        let sliceLookup = SliceLookup(slices: project.slices)
        frames.reserveCapacity(count)

        for i in 0..<count {
            let t = Double(i) * sampleIntervalMs
            let source = resolver.playbackToSource(t)
            let slice = sliceLookup.slice(atSource: source)
            let loupeTarget = planner.loupeTarget(at: source)
            let target = planner.targets(at: source, loupe: loupeTarget)
            let screenConfig = target.instant ? SpringConfig.instant : project.animation.screenSpring
            if i == 0 {
                screen = SpringRect(target.screen)
            } else {
                screen.advance(toward: target.screen, config: screenConfig, milliseconds: sampleIntervalMs)
            }

            // Camera: the fast spring while hidden and for 200 ms after.
            if target.cameraHidden { lastHiddenIndex = i }
            let recentlyHidden = lastHiddenIndex.map { i - $0 <= samplesFor200Ms } ?? false
            let cameraConfig = recentlyHidden ? Self.cameraHideSpring : project.animation.screenSpring
            if hasCamera, let rect = target.camera {
                if i == 0 || cameraRect.rect.width == 0 {
                    cameraRect = SpringRect(rect)
                    cameraRadius = SpringValue(target.cameraBorderRadius)
                    cameraReference = SpringValue(target.cameraReferenceWidth)
                    cutout = SpringValue(target.cameraCutout ? 1 : 0)
                    if i == 0 { cameraOpacity = SpringValue(target.cameraOpacity) }
                } else {
                    cameraRect.advance(toward: rect, config: cameraConfig, milliseconds: sampleIntervalMs)
                    cameraRadius.advance(toward: target.cameraBorderRadius, config: cameraConfig, milliseconds: sampleIntervalMs)
                    cameraReference.advance(toward: target.cameraReferenceWidth, config: cameraConfig, milliseconds: sampleIntervalMs)
                }
                if i > 0 {
                    cameraOpacity.advance(toward: target.cameraOpacity, config: cameraConfig, milliseconds: sampleIntervalMs)
                    cutout.advance(toward: target.cameraCutout ? 1 : 0, config: cameraConfig, milliseconds: sampleIntervalMs)
                }
            } else if hasCamera {
                cameraOpacity.advance(toward: 0, config: cameraConfig, milliseconds: sampleIntervalMs)
            }

            // Press scale (`pressSpring`): instant without smooth movement or in clips without it.
            let smooth = project.animation.mouseSpring != nil
            let pressSpring = !smooth || slice?.disableSmoothMouseMovement == true ? SpringConfig.instant : project.animation.mouseSpring!
            let pressed = CursorTypes.isPressed(at: source, events: pathEvents, clicks: buttonEvents, smoothed: smooth)
            press.setTarget(pressed ? Self.pressedCursorScale : 1, config: pressSpring)
            if i == 0 { press.snapToTarget() } else { press.advance(by: sampleIntervalMs, config: pressSpring) }

            var frame = CameraFrame(timeMs: t, screenRect: layout.toCanvas(screen.rect), cursor: cursorPlan.position(at: t))
            // The lens springs on its own (`styles.loupe`).
            if i == 0 { loupe = LoupeSpring(loupeTarget.frame) } else { loupe.advance(toward: loupeTarget.frame, config: planner.loupeSpring(at: source), milliseconds: sampleIntervalMs) }
            let lens = loupe.frame
            frame.loupe = lens.isVisible(recordingWidth: project.recording.videoSize.width, k: 0.1) ? lens : nil
            backdrop.advance(toward: planner.backdropTarget(at: source, loupeActive: loupeTarget.isActive, stage: stage), config: project.animation.screenSpring, milliseconds: sampleIntervalMs, first: i == 0)
            frame.backgroundRect = layout.toCanvas(backdrop.rect.rect)
            frame.backgroundBlurRadius = backdrop.blurRadius.value
            frame.frostBlurRadius = backdrop.frostBlurRadius.value
            frame.screenReferenceWidth = target.screenReferenceWidth * layout.scale
            frame.allowsScreenBorderRadius = target.allowsScreenBorderRadius
            frame.isBackgroundVisible = target.isBackgroundVisible
            if hasCamera, cameraRect.rect.width > 0 {
                let rect = cameraRect.rect
                frame.cameraRect = layout.toCanvas(rect)
                frame.cameraOpacity = clamp(cameraOpacity.value, 0, 1)
                frame.cameraSizeFactor = rect.width / max(cameraReference.value, 0.0001)
                frame.cameraCornerRadius = cameraRadius.value * frame.cameraSizeFactor * layout.scale
                frame.cameraCutout01 = clamp(cutout.value, 0, 1)
            }
            if hasCamera {
                var focal = FaceTracking.disabledCenter
                if project.camera.enableFaceTracking {
                    focal = FaceTracking.faceCenter01(confident: confidentFaces, cameraTimeMs: source + project.camera.delayAdjustmentMs, crop01: project.camera.crop01)
                }
                if project.camera.mirror { focal.x = 1 - focal.x }
                focalX.setTarget(focal.x, config: FaceTracking.spring)
                focalY.setTarget(focal.y, config: FaceTracking.spring)
                if i == 0 {
                    focalX.snapToTarget()
                    focalY.snapToTarget()
                } else {
                    focalX.advance(by: sampleIntervalMs, config: FaceTracking.spring)
                    focalY.advance(by: sampleIntervalMs, config: FaceTracking.spring)
                }
                frame.cameraFocal01 = Vec2(focalX.value, focalY.value)
            }
            frame.cursorScale = press.value
            frame.isInstantSnap = target.instant
            // Cursor opacity: fades out quickly while typing, otherwise follows visibility.
            let typing = Typing.isActivelyTyping(at: source, keystrokes: project.keystrokes, mouseEvents: sorted)
            let visible = slice?.hideCursor != true
                && Self.isCursorVisible(at: source, pathEvents: pathEvents, hideAfterMs: project.cursor.hideNotMovingAfterMs)
            let opacitySpring = typing ? Self.typingFadeSpring : Self.visibilitySpring
            opacity.setTarget(typing || !visible ? 0 : 1, config: opacitySpring)
            if i == 0 { opacity.snapToTarget() } else { opacity.advance(by: sampleIntervalMs, config: opacitySpring) }
            frame.cursorOpacity = opacity.value
            // Rotation: the base plus the motion rotation, sprung.
            rotation.setTarget(baseRotationRad + cursorPlan.motionRotation(at: t), config: rotationSpring)
            if i == 0 { rotation.snapToTarget() } else { rotation.advance(by: sampleIntervalMs, config: rotationSpring) }
            frame.cursorRotationRad = rotation.value
            // A fading cursor blurs toward 10 with the visibility spring; none when it is not drawn.
            if project.cursor.hide {
                fadeBlur = SpringValue(0)
            } else {
                fadeBlur.setTarget(typing || !visible ? Self.fadeOutBlurRadius : 0, config: Self.visibilitySpring)
                if i == 0 { fadeBlur.snapToTarget() } else { fadeBlur.advance(by: sampleIntervalMs, config: Self.visibilitySpring) }
            }
            frame.cursorFadeBlurRadius = fadeBlur.value
            frame.mask = maskAnimator.frame(at: source, stepMs: sampleIntervalMs, first: i == 0)
            frames.append(frame)
        }
        samples = frames
    }

    /// The frame at playback time `timeMs`, with the previous playback frame attached for motion blur.
    public func frame(at timeMs: Double) -> CameraFrame {
        var frame = interpolatedFrame(at: timeMs)
        let before = interpolatedMotion(at: max(0, timeMs - sampleIntervalMs))
        frame.previousScreenRect = before.screenRect
        frame.previousCursor = before.cursor
        frame.previousCursorScale = before.cursorScale
        frame.previousCursorRotationRad = before.cursorRotationRad
        frame.previousCameraRect = before.cameraRect
        return frame
    }

    /// The plain stage at playback time `timeMs`, shown while placing an item or editing a mask:
    /// the unzoomed screen alone on the default stage at its resting focus, without the loupe,
    /// the cursor, its click effect or the webcam. Nothing moves, so there is no motion blur.
    public func plainFrame(at timeMs: Double) -> CameraFrame {
        var frame = interpolatedFrame(at: timeMs)
        let source = resolver.playbackToSource(timeMs)
        let resting = planner.restingFocus(at: source)
        let screen = layout.toCanvas(plainResolver.screenRect(focus01: resting.center, bounds01: resting.bounds, level: 1))
        frame.screenRect = screen
        frame.previousScreenRect = screen
        frame.isInstantSnap = false
        frame.screenReferenceWidth = plainResolver.initialScreenRect.width * layout.scale
        frame.allowsScreenBorderRadius = plainResolver.allowsScreenBorderRadius
        frame.isBackgroundVisible = !(plainResolver.stageRect.width <= plainResolver.initialScreenRect.width
            && plainResolver.stageRect.height <= plainResolver.initialScreenRect.height)
        frame.loupe = nil
        frame.cursorOpacity = 0
        frame.previousCursor = nil
        frame.clicks = []
        frame.cameraOpacity = 0
        frame.previousCameraRect = nil
        return frame
    }

    /// The samples around playback time `timeMs` and the fraction between them.
    private func neighbours(at timeMs: Double) -> (a: CameraFrame, b: CameraFrame, f: Double) {
        let position = clamp(timeMs / sampleIntervalMs, 0, Double(samples.count - 1))
        let i0 = Int(position.rounded(.down))
        let i1 = min(i0 + 1, samples.count - 1)
        return (samples[i0], samples[i1], position - Double(i0))
    }

    /// Screen, cursor, press scale and camera placement of `interpolatedFrame(at:)`, without the rest.
    private func interpolatedMotion(at timeMs: Double) -> (screenRect: Rect2, cursor: Vec2?, cursorScale: Double, cursorRotationRad: Double, cameraRect: Rect2?) {
        guard let first = samples.first else { return (layout.restScreen, nil, 1, 0, nil) }
        let (a, b, f) = neighbours(at: timeMs)
        return (
            a.screenRect.lerp(to: b.screenRect, f),
            interpolate(a.cursor, b.cursor, f) ?? first.cursor,
            a.cursorScale + (b.cursorScale - a.cursorScale) * f,
            a.cursorRotationRad + (b.cursorRotationRad - a.cursorRotationRad) * f,
            Self.interpolate(a.cameraRect, b.cameraRect, f)
        )
    }

    private static func interpolate(_ a: Double?, _ b: Double?, _ f: Double) -> Double? {
        if let a, let b { return a + (b - a) * f }
        return a ?? b
    }

    private static func interpolate(_ a: Rect2?, _ b: Rect2?, _ f: Double) -> Rect2? {
        if let a, let b { return a.lerp(to: b, f) }
        return a ?? b
    }

    private func interpolatedFrame(at timeMs: Double) -> CameraFrame {
        guard let first = samples.first else {
            return CameraFrame(timeMs: timeMs, screenRect: layout.restScreen)
        }
        let (a, b, f) = neighbours(at: timeMs)
        var frame = CameraFrame(
            timeMs: timeMs,
            screenRect: a.screenRect.lerp(to: b.screenRect, f),
            cursor: interpolate(a.cursor, b.cursor, f) ?? first.cursor
        )
        frame.cursorOpacity = a.cursorOpacity + (b.cursorOpacity - a.cursorOpacity) * f
        frame.cursorScale = a.cursorScale + (b.cursorScale - a.cursorScale) * f
        frame.cursorRotationRad = a.cursorRotationRad + (b.cursorRotationRad - a.cursorRotationRad) * f
        frame.cursorFadeBlurRadius = a.cursorFadeBlurRadius + (b.cursorFadeBlurRadius - a.cursorFadeBlurRadius) * f
        frame.isInstantSnap = a.isInstantSnap || b.isInstantSnap
        frame.mask = Self.interpolate(a.mask, b.mask, f)
        frame.cameraRect = Self.interpolate(a.cameraRect, b.cameraRect, f)
        frame.cameraOpacity = a.cameraOpacity + (b.cameraOpacity - a.cameraOpacity) * f
        frame.cameraCornerRadius = a.cameraCornerRadius + (b.cameraCornerRadius - a.cameraCornerRadius) * f
        frame.cameraSizeFactor = a.cameraSizeFactor + (b.cameraSizeFactor - a.cameraSizeFactor) * f
        // Not sprung: these switch with the active layout.
        frame.screenReferenceWidth = a.screenReferenceWidth
        frame.allowsScreenBorderRadius = a.allowsScreenBorderRadius
        frame.isBackgroundVisible = a.isBackgroundVisible
        switch (a.loupe, b.loupe) {
        case let (la?, lb?): frame.loupe = la.lerp(to: lb, f)
        default: frame.loupe = f < 0.5 ? a.loupe : b.loupe
        }
        frame.cameraFocal01 = a.cameraFocal01.lerp(to: b.cameraFocal01, f)
        frame.backgroundRect = Self.interpolate(a.backgroundRect, b.backgroundRect, f)
        frame.backgroundBlurRadius = Self.interpolate(a.backgroundBlurRadius, b.backgroundBlurRadius, f)
        frame.frostBlurRadius = Self.interpolate(a.frostBlurRadius, b.frostBlurRadius, f)
        frame.cameraCutout01 = a.cameraCutout01 + (b.cameraCutout01 - a.cameraCutout01) * f
        let source = resolver.playbackToSource(timeMs)
        frame.cursorName = CursorTypes.assetName(at: source, typeEvents: typeEvents, names: typeEventNames, config: cursorConfig)
        if let effect = cursorConfig.clickEffect {
            frame.clicks = ClickEffects.recentClicks(at: source, presses: clicks, kind: effect.type)
        }
        return frame
    }

    /// Mouse events the drawn cursor follows, in source time: those between the start of the
    /// video and its end (minus "Loop cursor position"), the first moved to the start, and
    /// with looping the starting position again 1 ms after the last one.
    public static func cursorPathEvents(events: [MouseEvent], resolver: TimeResolver, config: CursorConfig) -> [MouseEvent] {
        let startMs = resolver.playbackToSource(0)
        let endMs = resolver.playbackToSource(max(0, resolver.playbackDurationMs - (config.loopPositionBeforeEndMs ?? 0)))
        var inRange = events.filter { $0.timeMs >= startMs && $0.timeMs <= endMs }
        if inRange.isEmpty {
            let before = MouseProcessing.lastIndex(atOrBefore: startMs, in: events).map { events[$0] }
            if let fallback = before ?? events.first { inRange = [fallback] }
        }
        guard !inRange.isEmpty else { return [] }
        inRange[0].timeMs = startMs
        if config.loopPositionBeforeEndMs != nil, let first = inRange.first, let last = inRange.last {
            var back = first
            back.timeMs = last.timeMs + 1
            inRange.append(back)
        }
        return inRange
    }

    /// Moments the smoothed cursor must reach the recorded position: presses, releases and
    /// drags. Tolerances are in points, converted to video pixels.
    public static func cursorSyncPoints(events: [MouseEvent], pointPixelScale: Double, cursorImageChangesMs: [Double] = [], hoverTimesMs: [Double] = []) -> [CursorSyncPoint] {
        var points: [CursorSyncPoint] = []
        func add(_ t: Double, _ reason: CursorSyncReason) {
            points.append(CursorSyncPoint(timeMs: t, reason: reason, tolerance: reason.tolerancePoints * pointPixelScale))
        }
        for event in events {
            switch event.kind {
            case .down, .up: add(event.timeMs, .click)
            case .drag: add(event.timeMs, .drag)
            case .move: break
            }
        }
        for t in hoverTimesMs { add(t, .hover) }
        for t in cursorImageChangesMs { add(t, .cursorImage) }
        return points.sorted { $0.timeMs < $1.timeMs }
    }

    /// Spring of a hiding or reappearing camera.
    public static let cameraHideSpring = SpringConfig(stiffness: 530, damping: 40, mass: 1)

    /// Spring for the cursor fading while typing.
    public static let typingFadeSpring = SpringConfig(stiffness: 600, damping: 50, mass: 1)
    /// Spring for showing and hiding the cursor.
    public static let visibilitySpring = SpringConfig(stiffness: 340, damping: 60, mass: 3)
    /// Blur of a hidden cursor, in stage units.
    public static let fadeOutBlurRadius = 10.0

    /// Whether the cursor should be shown at `t`: once the path starts and, with "Hide cursor
    /// if not moving", only while the last mouse event is at most that long ago.
    static func isCursorVisible(at t: Double, pathEvents: [MouseEvent], hideAfterMs: Double?) -> Bool {
        guard let first = pathEvents.first, t >= first.timeMs else { return false }
        guard let hideAfterMs else { return true }
        guard let i = floorSearch(count: pathEvents.count, value: t, key: { pathEvents[$0].timeMs }) else { return false }
        return abs(pathEvents[i].timeMs - t) <= hideAfterMs
    }

    private static func interpolate(_ a: MaskFrame, _ b: MaskFrame, _ t: Double) -> MaskFrame {
        var m = t < 0.5 ? a : b
        if a.type == b.type && a.active == b.active {
            m.bounds01 = a.bounds01.lerp(to: b.bounds01, t)
            m.borderRadius01 = a.borderRadius01 + (b.borderRadius01 - a.borderRadius01) * t
            m.highlightOpacity = a.highlightOpacity + (b.highlightOpacity - a.highlightOpacity) * t
        }
        m.opacity = a.opacity + (b.opacity - a.opacity) * t
        return m
    }

    private func interpolate(_ a: Vec2?, _ b: Vec2?, _ t: Double) -> Vec2? {
        switch (a, b) {
        case let (a?, b?): return a.lerp(to: b, t)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

/// Targets of one instant, in stage units, before spring smoothing.
struct LayoutTargets {
    var screen: Rect2
    var instant: Bool
    var camera: Rect2?
    var cameraOpacity: Double
    var cameraBorderRadius: Double
    var cameraReferenceWidth: Double
    var cameraHidden: Bool
    /// The camera's layout is a cutout (`isCutout`).
    var cameraCutout: Bool
    var screenReferenceWidth: Double
    var allowsScreenBorderRadius: Bool
    var isBackgroundVisible: Bool
}

/// Decides, for any instant, where the screen and the camera want to be (rects, resolvers).
struct CameraPlanner {
    let project: Project
    let timeline: LayoutTimeline
    let cleaned: [MouseEvent]
    /// The events the drawn cursor follows (`cursorPathEvents`): resting focus and auto-zoom
    /// groups come from them.
    let pathEvents: [MouseEvent]
    /// Enabled zooms that move the screen (not loupes), ordered by start.
    let zooms: [ZoomRange]
    /// Every zoom ordered by start, ties in project order.
    let allZoomsByStart: [ZoomRange]
    /// Enabled zooms of any kind with an instant animation.
    let instantZooms: [ZoomRange]
    /// Enabled glass loupe zooms.
    let loupes: [ZoomRange]
    let groups: [UUID: [FocusGroup]]
    /// Cursor "moves groups" for the resting focus.
    let restingGroups: [FocusGroup]
    /// Quiet stretches of the microphone for "Hide during silence".
    let silence: [SilenceChunk]
    /// Enabled zooms of any kind ordered by end, then by start, ties in project order.
    let enabledZoomsByEnd: [ZoomRange]
    let enabledZoomsByStart: [ZoomRange]

    init(project: Project, timeline: LayoutTimeline, cleaned: [MouseEvent], pathEvents: [MouseEvent], silence: [SilenceChunk] = []) {
        self.project = project
        self.silence = silence
        self.timeline = timeline
        self.cleaned = cleaned
        self.pathEvents = pathEvents
        // Any enabled screen zoom moves the screen, a 1× one included.
        zooms = project.zooms
            .filter { !$0.isDisabled && $0.presentation == .screen }
            .sorted { $0.startMs < $1.startMs }
        loupes = project.zooms
            .filter { !$0.isDisabled && $0.presentation == .loupe && $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        allZoomsByStart = project.zooms.enumerated()
            .sorted { $0.element.startMs != $1.element.startMs ? $0.element.startMs < $1.element.startMs : $0.offset < $1.offset }
            .map(\.element)
        instantZooms = allZoomsByStart.filter { $0.isInstant && !$0.isDisabled }
        let enabled = project.zooms.enumerated().filter { !$0.element.isDisabled }
        enabledZoomsByEnd = enabled
            .sorted { $0.element.endMs != $1.element.endMs ? $0.element.endMs < $1.element.endMs : $0.offset < $1.offset }
            .map(\.element)
        enabledZoomsByStart = enabled
            .sorted { $0.element.startMs != $1.element.startMs ? $0.element.startMs < $1.element.startMs : $0.offset < $1.offset }
            .map(\.element)

        // Thinned to one event every 10 points, presses and releases always kept.
        let sparse = MouseProcessing.downsample(pathEvents, minDistance: 10 * project.recording.pointPixelScale)
        var groups: [UUID: [FocusGroup]] = [:]
        let sparseAscending = isAscending(count: sparse.count) { sparse[$0].timeMs }
        let smooth = project.animation.mouseSpring != nil
        // Every auto zoom, disabled ones included: one carried behind a fullscreen camera may be.
        for zoom in allZoomsByStart where zoom.mode == .auto {
            var events = indices(count: sparse.count, ascending: sparseAscending, from: zoom.startMs, through: zoom.endMs, key: { sparse[$0].timeMs }).map { sparse[$0] }
            // An event right at the start is also counted 1 ms before it.
            if let first = events.first, first.timeMs == zoom.startMs {
                var carried = first
                carried.timeMs = zoom.startMs - 1
                events.insert(carried, at: 0)
            }
            if events.isEmpty, let fallback = Self.eventNear(zoom.startMs, pathEvents: pathEvents, smooth: smooth) {
                events = [fallback]
            }
            // A group may span at most half of what is visible at this zoom level, as laid out
            // when the zoom starts.
            let extent = Self.visibleEventExtent(project: project, resolver: Self.screenResolver(timeline, project: project, at: zoom.startMs), level: zoom.scale)
            groups[zoom.id] = FocusGrouping.build(events: events, maxExtent: extent)
        }
        self.groups = groups
        restingGroups = FocusGrouping.build(
            events: pathEvents,
            maxExtent: Self.visibleEventExtent(project: project, resolver: timeline.defaultResolver, level: 1)
        )
    }

    /// The screen's layout at `t` before zoom variants, hiding the camera when it is off.
    static func screenResolver(_ timeline: LayoutTimeline, project: Project, at t: Double) -> LayoutResolver {
        let resolver = timeline.screenResolver(at: t)
        return project.camera.hide ? resolver.hideCameraVariant : resolver
    }

    /// Half of the source visible at `level` (`getVisibleSourcePart(level) × 0.5`), in video
    /// pixels. The layout measures the recording in points, so the comparison with the stage
    /// is made in points and the result converted back.
    static func visibleEventExtent(project: Project, resolver: LayoutResolver, level: Double) -> Size2 {
        let ppp = max(project.recording.pointPixelScale, 0.0001)
        let deviceFrame = project.activeDeviceFrame != nil
        let source = deviceFrame ? resolver.sourceRect.size : Size2(width: resolver.sourceRect.width / ppp, height: resolver.sourceRect.height / ppp)
        let visible = LayoutResolver.visibleSourcePart(stage: resolver.stageRect.size, source: source, level: level)
        return Size2(width: visible.width * 0.5 * ppp, height: visible.height * 0.5 * ppp)
    }

    /// Where an auto zoom without events looks: with smooth movement, a press or release
    /// within 500 ms after `t`; otherwise the event at or before `t`, else the next one.
    static func eventNear(_ t: Double, pathEvents: [MouseEvent], smooth: Bool) -> MouseEvent? {
        if smooth {
            let buttons = pathEvents.filter(\.isClick)
            if let i = ceilSearch(count: buttons.count, value: t, key: { buttons[$0].timeMs }), buttons[i].timeMs - t <= 500 {
                return buttons[i]
            }
        }
        let i = floorSearch(count: pathEvents.count, value: t, key: { pathEvents[$0].timeMs })
            ?? ceilSearch(count: pathEvents.count, value: t, key: { pathEvents[$0].timeMs })
        return i.map { pathEvents[$0] }
    }

    /// The zoom moving the screen (`screenMovingRange`): the active zoom, the next one within its
    /// lead-in, or the previous one carried behind a fullscreen camera.
    func activeZoom(at t: Double) -> ZoomRange? {
        if let zoom = zooms.last(where: { $0.contains(t) }) { return zoom }
        // The lead-in into the next zoom, unless an enabled zoom (a loupe) holds `t`.
        let lead = project.animation.leadInMs
        if !project.zooms.contains(where: { $0.contains(t) && !$0.isDisabled }), lead > 0,
           let next = zooms.first(where: { $0.startMs >= t }), !next.isInstant, t >= next.startMs - lead {
            return next
        }
        // Behind a fullscreen camera: the zoom that ended last, unless it is a loupe.
        if let range = timeline.activeRange(at: t), range.type == .fullscreenCamera,
           let i = floorSearch(count: allZoomsByStart.count, value: t, key: { allZoomsByStart[$0].endMs }) {
            let previous = allZoomsByStart[i]
            if previous.presentation == .loupe || previous.endMs < range.startMs { return nil }
            return t < range.startMs + 0.85 * range.durationMs ? previous : nil
        }
        return nil
    }

    /// Where `zoom` looks at `t`; nil for an auto zoom with no cursor to follow, which leaves
    /// the screen at its resting focus.
    func focus(for zoom: ZoomRange, at t: Double) -> Vec2? {
        let video = project.recording.videoSize
        switch zoom.mode {
        case .manual:
            return zoom.manualTarget
        case .auto:
            guard let point = FocusGrouping.group(at: t, in: groups[zoom.id] ?? [])?.center else { return nil }
            return Vec2(clamp(point.x / video.width, 0, 1), clamp(point.y / video.height, 0, 1))
        }
    }

    /// Screen focus at zoom 1 (`restingFocus01`): the centre of the current moves group (or the
    /// middle), with the cursor bounds over the next 350 ms.
    func restingFocus(at t: Double) -> (center: Vec2, bounds: Rect2?) {
        let video = project.recording.videoSize
        let group = floorSearch(count: restingGroups.count, value: t, key: { restingGroups[$0].startMs }).map { restingGroups[$0] }
        let center = group.map { Vec2($0.center.x / video.width, $0.center.y / video.height) } ?? .center01
        guard let b = Self.cursorBounds(pathEvents, from: t, to: t + 350) else { return (center, nil) }
        return (center, Rect2(x: b.x / video.width, y: b.y / video.height, width: b.width / video.width, height: b.height / video.height))
    }

    /// Bounds of the cursor from the event at or before `start` through those up to `end`.
    static func cursorBounds(_ events: [MouseEvent], from start: Double, to end: Double) -> Rect2? {
        let floor = MouseProcessing.lastIndex(atOrBefore: start, in: events)
        // First and last events within [start, end].
        var inRange: (first: Int, last: Int)?
        if let lo = ceilSearch(count: events.count, value: start, key: { events[$0].timeMs }),
           let hi = MouseProcessing.lastIndex(atOrBefore: end, in: events), lo <= hi {
            inRange = (lo, hi)
        }
        guard let first = floor ?? inRange?.first, let last = inRange?.last ?? floor else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in first...last {
            let p = events[i].position
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return Rect2(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Any enabled instant zoom, loupes included, snaps the screen until 50 ms after its end.
    func isInInstantWindow(_ t: Double) -> Bool {
        instantZooms.contains { t >= $0.startMs && t <= $0.endMs + 50 }
    }

    /// `getIsHiddenAtTime`: never in a fullscreen-camera range; hidden during a long silence
    /// when "Hide during silence" is on, or by a screen-only range.
    func isCameraHidden(at t: Double) -> Bool {
        if timeline.activeRange(at: t)?.type == .fullscreenCamera { return false }
        if let ms = project.camera.hideDuringSilenceMs, SilenceDetection.isSilent(silence, at: t, hideDuringSilenceMs: ms) { return true }
        return timeline.isCameraHidden(at: t)
    }

    /// `loupe` is `loupeTarget(at: t)`.
    func targets(at t: Double, loupe: (frame: LoupeFrame, isActive: Bool)) -> LayoutTargets {
        let hidden = isCameraHidden(at: t)
        let swapToHideVariant = hidden || project.camera.hide
        let anyZoom = project.zooms.contains { $0.contains(t) }
        func variant(_ r: LayoutResolver) -> LayoutResolver {
            var r = r
            if swapToHideVariant { r = r.hideCameraVariant }
            if anyZoom { r = r.zoomedVariant }
            return r
        }
        let screenResolver = variant(timeline.screenResolver(at: t))
        let cameraResolver = variant(timeline.cameraResolver(at: t))
        let zoom = activeZoom(at: t)
        let screen: Rect2
        if let zoom, let focus = focus(for: zoom, at: t) {
            screen = screenResolver.screenRect(focus01: focus, level: zoom.scale)
        } else {
            let resting = restingFocus(at: t)
            screen = screenResolver.screenRect(focus01: resting.center, bounds01: resting.bounds, level: 1)
        }

        var camera = zoom != nil ? cameraResolver.effectiveZoomedCameraRect : cameraResolver.cameraRect
        if hidden, let c = camera {
            // Shrinks toward its centre expressed over the screen size (literal).
            let origin = Vec2(clamp((c.x + c.width / 2) / screen.width, 0, 1), clamp((c.y + c.height / 2) / screen.height, 0, 1))
            camera = c.scaled(0.9, origin01: origin)
        }
        let initial = cameraResolver.cameraRect
        let radius = cameraResolver.allowsCameraBorderRadius ? (initial?.shortestSide ?? 0) * project.style.cameraBorderRadiusRatio : 0
        return LayoutTargets(
            screen: screen,
            instant: isInInstantWindow(t),
            camera: camera,
            cameraOpacity: hidden || camera == nil || (camera.map { isCameraCoveredByLoupe(camera: $0, screen: screen, target: loupe) } ?? false) ? 0 : 1,
            cameraBorderRadius: radius,
            cameraReferenceWidth: initial?.width ?? camera?.width ?? 1,
            cameraHidden: hidden,
            cameraCutout: cameraResolver.kind == .cutout,
            screenReferenceWidth: screenResolver.initialScreenRect.width,
            allowsScreenBorderRadius: screenResolver.allowsScreenBorderRadius,
            isBackgroundVisible: !(screenResolver.stageRect.width <= screenResolver.initialScreenRect.width && screenResolver.stageRect.height <= screenResolver.initialScreenRect.height)
        )
    }
}

/// Planning the cursor is the expensive part of a track and does not depend on zooms or styles,
/// so the last plan (and the chunks it has made) is reused while the inputs stay the same.
final class CursorPathCache: @unchecked Sendable {
    static let shared = CursorPathCache()
    private let lock = NSLock()
    private var entry: CursorPlan?

    func plan(for inputs: CursorPlan.Inputs) -> CursorPlan {
        lock.lock()
        defer { lock.unlock() }
        if let entry, entry.inputs == inputs { return entry }
        let plan = CursorPlan(inputs: inputs)
        entry = plan
        return plan
    }
}

/// Where the background wants to be (`rects.background`, `background.blurRadius` and
/// `frostBlurRadius`), in stage units.
struct BackdropTarget: Equatable {
    var rect: Rect2
    var blurRadius: Double
    var frostBlurRadius: Double
}

/// The background's placement and blurs, sprung together with the screen movement spring.
struct BackdropSpring {
    var rect = SpringRect(Rect2(x: 0, y: 0, width: 0, height: 0))
    var blurRadius = SpringValue(0)
    var frostBlurRadius = SpringValue(0)

    mutating func advance(toward target: BackdropTarget, config: SpringConfig, milliseconds: Double, first: Bool) {
        if first {
            rect = SpringRect(target.rect)
            blurRadius = SpringValue(target.blurRadius)
            frostBlurRadius = SpringValue(target.frostBlurRadius)
            return
        }
        rect.advance(toward: target.rect, config: config, milliseconds: milliseconds)
        blurRadius.advance(toward: target.blurRadius, config: config, milliseconds: milliseconds)
        frostBlurRadius.advance(toward: target.frostBlurRadius, config: config, milliseconds: milliseconds)
    }
}

extension CameraPlanner {
    /// The background grows by 1/8 of every zoom step beyond 1.
    static let backgroundZoomPerStep = 0.125
    /// Stage pixels of background blur per zoom level while the screen zooms, when the
    /// style has no blur.
    static let zoomBlurPerLevel = 8.0
    /// The loupe's frost, as a share of the stage width.
    static let frostBlurShare = 0.005

    /// While a zoom moves the screen the background scales by 1 + (zoom − 1) / 8 around the
    /// zoom's point (the screen's focus), rounded outward.
    func backdropTarget(at t: Double, loupeActive: Bool, stage: Rect2) -> BackdropTarget {
        let styleBlur = project.style.background.blurRadius(stageWidth: stage.width)
        let frost = loupeActive ? stage.width * Self.frostBlurShare : 0
        guard let zoom = activeZoom(at: t) else {
            return BackdropTarget(rect: stage, blurRadius: styleBlur, frostBlurRadius: frost)
        }
        let k = 1 + max(0, zoom.scale - 1) * Self.backgroundZoomPerStep
        // Without a focus the screen holds its resting focus, and so does the background.
        let point = focus(for: zoom, at: t) ?? restingFocus(at: t).center
        let scaled = stage.scaled(k, origin01: Vec2(clamp(point.x, 0, 1), clamp(point.y, 0, 1)))
        let rect = Rect2(x: scaled.x.rounded(.down), y: scaled.y.rounded(.down), width: scaled.width.rounded(.up), height: scaled.height.rounded(.up))
        return BackdropTarget(rect: rect, blurRadius: styleBlur > 0 ? styleBlur : Self.zoomBlurPerLevel * zoom.scale, frostBlurRadius: frost)
    }
}
