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

    static func scaled(_ r: Rect2, _ k: Double) -> Rect2 {
        Rect2(x: r.x * k, y: r.y * k, width: r.width * k, height: r.height * k)
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
    /// Inside an instant zoom's snap window (motion blur is off there).
    public var isInstantSnap = false
    /// The same values one project frame earlier, for motion blur.
    public var previousScreenRect: Rect2?
    public var previousCursor: Vec2?
    public var previousCursorScale: Double = 1
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
    /// Click effect: 0...1 progress and position in video pixels.
    public var clickProgress: Double?
    public var clickPosition: Vec2?
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
    public static let clickRippleMs: Double = 450

    /// Scale of the cursor while a button is held.
    public static let pressedCursorScale = 0.9

    private let samples: [CameraFrame]
    private let clicks: [MouseEvent]
    private let typeEvents: [MouseEvent]
    private let cursorConfig: CursorConfig

    public init(project: Project, faces: CameraFaces? = nil, silence: [SilenceChunk] = [], sampleRateHz: Double? = nil) {
        let layout = CanvasLayout(project: project)
        self.layout = layout
        let timeline = LayoutTimeline(project: project)
        let resolver = project.resolver
        self.resolver = resolver
        durationMs = max(resolver.playbackDurationMs, 0)
        sampleIntervalMs = 1000 / (sampleRateHz ?? Double(max(project.recording.fps, 1)))

        let sorted = project.mouseEvents.sorted { $0.timeMs < $1.timeMs }
        let cleaned = MouseProcessing.removeSpikes(sorted, threshold: project.cursor.removeShakeThreshold)
        let sparse = MouseProcessing.downsample(cleaned, minDistance: 10 * project.recording.pointPixelScale)
        clicks = cleaned.filter { $0.kind == .down }
        cursorConfig = project.cursor
        let typeEvents = CursorTypes.typeEvents(cleaned, config: project.cursor)
        self.typeEvents = typeEvents
        let imageChanges = CursorTypes.imageChangeTimes(typeEvents, config: project.cursor)
        let pathEvents = Self.cursorPathEvents(events: cleaned, resolver: resolver, config: project.cursor)

        let planner = CameraPlanner(project: project, timeline: timeline, cleaned: cleaned, sparse: sparse, silence: silence)

        let cursorPath = CursorPathCache.shared.path(
            for: CursorPathCache.Key(
                events: cleaned,
                slices: project.slices,
                loopMs: project.cursor.loopPositionBeforeEndMs,
                spring: project.animation.mouseSpring,
                pointPixelScale: project.recording.pointPixelScale,
                imageChangesMs: imageChanges
            )
        ) {
            Self.planCursor(
                pathEvents: pathEvents,
                imageChangesMs: imageChanges,
                slices: project.slices,
                resolver: resolver,
                spring: project.animation.mouseSpring,
                pointPixelScale: project.recording.pointPixelScale
            )
        }

        var screen = SpringRect(timeline.defaultResolver.initialScreenRect)
        var cameraRect = SpringRect(Rect2(x: 0, y: 0, width: 0, height: 0))
        var cameraOpacity = SpringValue(0)
        var cameraRadius = SpringValue(0)
        var cameraReference = SpringValue(1)
        let hasCamera = project.recording.hasCamera && !project.camera.hide
        let samplesFor200Ms = Int((200 / sampleIntervalMs).rounded(.up))
        var hiddenHistory: [Bool] = []
        var maskAnimator = MaskAnimator(masks: project.masks, recordingSize: project.recording.videoSize)
        var press = SpringValue(1)
        var opacity = SpringValue(1)
        // Face tracking: the focal point always uses its own spring.
        let confidentFaces = project.camera.enableFaceTracking ? FaceTracking.confident(faces) : nil
        var focalX = SpringValue(0.5), focalY = SpringValue(0.5)
        var cutout = SpringValue(0)
        let buttonEvents = pathEvents.filter(\.isClick)
        var frames: [CameraFrame] = []
        let count = Int((durationMs / sampleIntervalMs).rounded(.up)) + 2
        frames.reserveCapacity(count)

        for i in 0..<count {
            let t = Double(i) * sampleIntervalMs
            let source = resolver.playbackToSource(t)
            let slice = project.slice(atSource: source)
            let target = planner.targets(at: source)
            let screenConfig = target.instant ? SpringConfig.instant : project.animation.screenSpring
            if i == 0 {
                screen = SpringRect(target.screen)
            } else {
                screen.advance(toward: target.screen, config: screenConfig, milliseconds: sampleIntervalMs)
            }

            // Camera: the fast spring while hidden and for 200 ms after.
            hiddenHistory.append(target.cameraHidden)
            let recentlyHidden = hiddenHistory.suffix(samplesFor200Ms + 1).contains(true)
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

            var frame = CameraFrame(timeMs: t, screenRect: layout.toCanvas(screen.rect), cursor: cursorPath?.position(at: t))
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
            let typing = Typing.isActivelyTyping(at: source, keystrokes: project.keystrokes, mouseEvents: cleaned)
            let visible = slice?.hideCursor != true
                && Self.isCursorVisible(at: source, pathEvents: pathEvents, hideAfterMs: project.cursor.hideNotMovingAfterMs)
            let opacitySpring = typing ? Self.typingFadeSpring : Self.visibilitySpring
            opacity.setTarget(typing || !visible ? 0 : 1, config: opacitySpring)
            if i == 0 { opacity.snapToTarget() } else { opacity.advance(by: sampleIntervalMs, config: opacitySpring) }
            frame.cursorOpacity = opacity.value
            frame.mask = maskAnimator.frame(at: source, stepMs: sampleIntervalMs, first: i == 0)
            frames.append(frame)
        }
        samples = frames
    }

    /// The frame at playback time `timeMs`, with the previous project frame attached for motion blur.
    public func frame(at timeMs: Double) -> CameraFrame {
        var frame = interpolatedFrame(at: timeMs)
        let before = interpolatedFrame(at: max(0, timeMs - sampleIntervalMs))
        frame.previousScreenRect = before.screenRect
        frame.previousCursor = before.cursor
        frame.previousCursorScale = before.cursorScale
        return frame
    }

    private func interpolatedFrame(at timeMs: Double) -> CameraFrame {
        guard let first = samples.first else {
            return CameraFrame(timeMs: timeMs, screenRect: layout.restScreen)
        }
        let position = clamp(timeMs / sampleIntervalMs, 0, Double(samples.count - 1))
        let i0 = Int(position.rounded(.down))
        let i1 = min(i0 + 1, samples.count - 1)
        let f = position - Double(i0)
        let a = samples[i0], b = samples[i1]
        var frame = CameraFrame(
            timeMs: timeMs,
            screenRect: a.screenRect.lerp(to: b.screenRect, f),
            cursor: interpolate(a.cursor, b.cursor, f) ?? first.cursor
        )
        frame.cursorOpacity = a.cursorOpacity + (b.cursorOpacity - a.cursorOpacity) * f
        frame.cursorScale = a.cursorScale + (b.cursorScale - a.cursorScale) * f
        frame.isInstantSnap = a.isInstantSnap || b.isInstantSnap
        frame.mask = Self.interpolate(a.mask, b.mask, f)
        if let ca = a.cameraRect, let cb = b.cameraRect {
            frame.cameraRect = ca.lerp(to: cb, f)
        } else {
            frame.cameraRect = a.cameraRect ?? b.cameraRect
        }
        frame.cameraOpacity = a.cameraOpacity + (b.cameraOpacity - a.cameraOpacity) * f
        frame.cameraCornerRadius = a.cameraCornerRadius + (b.cameraCornerRadius - a.cameraCornerRadius) * f
        frame.cameraSizeFactor = a.cameraSizeFactor + (b.cameraSizeFactor - a.cameraSizeFactor) * f
        // Not sprung: these switch with the active layout.
        frame.screenReferenceWidth = a.screenReferenceWidth
        frame.allowsScreenBorderRadius = a.allowsScreenBorderRadius
        frame.isBackgroundVisible = a.isBackgroundVisible
        frame.cameraFocal01 = a.cameraFocal01.lerp(to: b.cameraFocal01, f)
        frame.cameraCutout01 = a.cameraCutout01 + (b.cameraCutout01 - a.cameraCutout01) * f
        let source = resolver.playbackToSource(timeMs)
        frame.cursorName = CursorTypes.assetName(at: source, typeEvents: typeEvents, config: cursorConfig)
        if let i = MouseProcessing.lastIndex(atOrBefore: source, in: clicks) {
            let age = source - clicks[i].timeMs
            if age >= 0 && age < Self.clickRippleMs {
                frame.clickProgress = age / Self.clickRippleMs
                frame.clickPosition = clicks[i].position
            }
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

    /// Plans the drawn cursor in playback time: per clip, the position at its start plus its
    /// events mapped to playback time; sync points likewise; clips that follow a cut reset
    /// the lead, and clips without smooth movement are instant.
    static func planCursor(
        pathEvents: [MouseEvent],
        imageChangesMs: [Double],
        slices: [Slice],
        resolver: TimeResolver,
        spring: SpringConfig?,
        pointPixelScale: Double
    ) -> SmoothedCursorPath? {
        guard !pathEvents.isEmpty else { return nil }
        var points: [CursorPathPoint] = []
        var syncEvents: [MouseEvent] = []
        var imageChanges: [Double] = []
        var cuts: [Double] = []
        var instant: [TimeRange] = []
        for (index, link) in resolver.links.enumerated() {
            let atStart = MouseProcessing.lastIndex(atOrBefore: link.sourceStartMs, in: pathEvents).map { pathEvents[$0] } ?? pathEvents[0]
            points.append(CursorPathPoint(timeMs: link.playbackStartMs, position: atStart.position))
            for event in pathEvents where event.timeMs >= link.sourceStartMs && event.timeMs <= link.sourceEndMs {
                let t = link.sourceToPlayback(event.timeMs)
                points.append(CursorPathPoint(timeMs: t, position: event.position))
                var mapped = event
                mapped.timeMs = t
                syncEvents.append(mapped)
            }
            for change in imageChangesMs where change >= link.sourceStartMs && change <= link.sourceEndMs {
                imageChanges.append(link.sourceToPlayback(change))
            }
            if index > 0, resolver.links[index - 1].sourceEndMs != link.sourceStartMs {
                cuts.append(link.playbackStartMs)
            }
            if slices.indices.contains(index), slices[index].disableSmoothMouseMovement {
                instant.append(TimeRange(startMs: link.playbackStartMs, endMs: link.playbackEndMs))
            }
        }
        points.sort { $0.timeMs < $1.timeMs }
        return SmoothedCursorPath.plan(
            points: points,
            syncPoints: cursorSyncPoints(events: syncEvents, pointPixelScale: pointPixelScale, cursorImageChangesMs: imageChanges),
            spring: spring,
            durationMs: resolver.playbackDurationMs,
            instantRanges: instant,
            cutTimesMs: cuts
        )
    }

    /// Moments the smoothed cursor must reach the recorded position: presses, releases and
    /// drags. Tolerances are in points, converted to video pixels.
    public static func cursorSyncPoints(events: [MouseEvent], pointPixelScale: Double, cursorImageChangesMs: [Double] = []) -> [CursorSyncPoint] {
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
        for t in cursorImageChangesMs { add(t, .cursorImage) }
        return points.sorted { $0.timeMs < $1.timeMs }
    }

    /// Spring of a hiding or reappearing camera.
    public static let cameraHideSpring = SpringConfig(stiffness: 530, damping: 40, mass: 1)

    /// Spring for the cursor fading while typing.
    public static let typingFadeSpring = SpringConfig(stiffness: 600, damping: 50, mass: 1)
    /// Spring for showing and hiding the cursor.
    public static let visibilitySpring = SpringConfig(stiffness: 340, damping: 60, mass: 3)

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
    let zooms: [ZoomRange]
    let groups: [UUID: [FocusGroup]]
    /// Cursor "moves groups" for the resting focus.
    let restingGroups: [FocusGroup]
    /// Quiet stretches of the microphone for "Hide during silence".
    let silence: [SilenceChunk]

    init(project: Project, timeline: LayoutTimeline, cleaned: [MouseEvent], sparse: [MouseEvent], silence: [SilenceChunk] = []) {
        self.project = project
        self.silence = silence
        self.timeline = timeline
        self.cleaned = cleaned
        zooms = project.zooms
            .filter { !$0.isDisabled && $0.presentation == .screen && $0.scale > 1 && $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }

        let video = project.recording.videoSize
        var groups: [UUID: [FocusGroup]] = [:]
        for zoom in zooms where zoom.mode == .auto {
            var events = sparse.filter { $0.timeMs >= zoom.startMs && $0.timeMs <= zoom.endMs }
            // Include where the cursor already was when the zoom starts.
            if let i = MouseProcessing.lastIndex(atOrBefore: zoom.startMs, in: sparse), sparse[i].timeMs < zoom.startMs {
                var carried = sparse[i]
                carried.timeMs = zoom.startMs - 1
                events.insert(carried, at: 0)
            }
            // A group may span at most half of what is visible at this zoom level.
            let extent = Size2(width: video.width / zoom.scale * 0.5, height: video.height / zoom.scale * 0.5)
            groups[zoom.id] = FocusGrouping.build(events: events, maxExtent: extent, endMs: zoom.endMs)
        }
        self.groups = groups
        let visible = timeline.defaultResolver.visibleSourcePart(level: 1)
        restingGroups = FocusGrouping.build(
            events: sparse,
            maxExtent: Size2(width: visible.width * 0.5, height: visible.height * 0.5),
            endMs: project.recording.durationMs
        )
    }

    /// The zoom moving the screen (`screenMovingRange`): the active zoom, the next one within its
    /// lead-in, or the previous one carried behind a fullscreen camera.
    func activeZoom(at t: Double) -> ZoomRange? {
        if let zoom = zooms.last(where: { $0.contains(t) }) { return zoom }
        let lead = project.animation.leadInMs
        if !project.zooms.contains(where: { $0.contains(t) }), lead > 0,
           let next = zooms.first(where: { $0.startMs > t }), !next.isInstant, t >= next.startMs - lead {
            return next
        }
        if let range = timeline.activeRange(at: t), range.type == .fullscreenCamera,
           t < range.startMs + 0.85 * range.durationMs,
           let previous = zooms.last(where: { $0.startMs <= t }), previous.endMs >= range.startMs {
            return previous
        }
        return nil
    }

    func focus(for zoom: ZoomRange, at t: Double) -> Vec2 {
        let video = project.recording.videoSize
        switch zoom.mode {
        case .manual:
            return zoom.manualTarget
        case .auto:
            let point = FocusGrouping.group(at: t, in: groups[zoom.id] ?? [])?.center
                ?? MouseProcessing.position(at: zoom.startMs, in: cleaned)
            guard let point else { return .center01 }
            return Vec2(clamp(point.x / video.width, 0, 1), clamp(point.y / video.height, 0, 1))
        }
    }

    /// Screen focus at zoom 1 (`restingFocus01`): the centre of the current moves group (or the
    /// middle), with the cursor bounds over the next 350 ms.
    func restingFocus(at t: Double) -> (center: Vec2, bounds: Rect2?) {
        let video = project.recording.videoSize
        let group = restingGroups.last { ($0.events.first?.timeMs ?? .infinity) <= t }
        let center = group.map { Vec2($0.center.x / video.width, $0.center.y / video.height) } ?? .center01
        guard let b = Self.cursorBounds(cleaned, from: t, to: t + 350) else { return (center, nil) }
        return (center, Rect2(x: b.x / video.width, y: b.y / video.height, width: b.width / video.width, height: b.height / video.height))
    }

    /// Bounds of the cursor from the event at or before `start` through those up to `end`.
    static func cursorBounds(_ events: [MouseEvent], from start: Double, to end: Double) -> Rect2? {
        let floor = MouseProcessing.lastIndex(atOrBefore: start, in: events)
        let inRange = events.indices.filter { events[$0].timeMs >= start && events[$0].timeMs <= end }
        guard let first = floor ?? inRange.first, let last = inRange.last ?? floor else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in first...last {
            let p = events[i].position
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return Rect2(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func isInInstantWindow(_ t: Double) -> Bool {
        zooms.contains { $0.isInstant && t >= $0.startMs && t <= $0.endMs + 50 }
    }

    /// `getIsHiddenAtTime`: never in a fullscreen-camera range; hidden during a long silence
    /// when "Hide during silence" is on, or by a screen-only range.
    func isCameraHidden(at t: Double) -> Bool {
        if timeline.activeRange(at: t)?.type == .fullscreenCamera { return false }
        if let ms = project.camera.hideDuringSilenceMs, SilenceDetection.isSilent(silence, at: t, hideDuringSilenceMs: ms) { return true }
        return timeline.isCameraHidden(at: t)
    }

    func targets(at t: Double) -> LayoutTargets {
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
        if let zoom {
            screen = screenResolver.screenRect(focus01: focus(for: zoom, at: t), level: zoom.scale)
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
            cameraOpacity: hidden || camera == nil ? 0 : 1,
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
/// so the last result is reused while the inputs stay the same.
final class CursorPathCache: @unchecked Sendable {
    struct Key: Equatable {
        var events: [MouseEvent]
        var slices: [Slice]
        var loopMs: Double?
        var spring: SpringConfig?
        var pointPixelScale: Double
        var imageChangesMs: [Double]
    }

    static let shared = CursorPathCache()
    private let lock = NSLock()
    private var entry: (key: Key, path: SmoothedCursorPath?)?

    func path(for key: Key, make: () -> SmoothedCursorPath?) -> SmoothedCursorPath? {
        lock.lock()
        if let entry, entry.key == key {
            lock.unlock()
            return entry.path
        }
        lock.unlock()
        let path = make()
        lock.lock()
        entry = (key, path)
        lock.unlock()
        return path
    }
}
