import Foundation

/// Where things sit on the output canvas.
public struct CanvasLayout: Hashable, Sendable {
    public let canvas: Rect2
    /// Screen rectangle when not zoomed.
    public let restScreen: Rect2
    /// Area the zoomed screen must cover.
    public let zoomArea: Rect2
    public let videoSize: Size2

    public init(style: StyleConfig, videoSize: Size2) {
        canvas = Rect2(size: style.canvasSize(videoSize: videoSize))
        let padding = min(canvas.width, canvas.height) * style.paddingRatio
        restScreen = Rect2.aspectFit(videoSize, in: canvas.insetBy(padding))
        zoomArea = style.zoomFillsCanvas ? canvas : restScreen
        self.videoSize = videoSize
    }

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
    /// Click effect: 0...1 progress and position in video pixels.
    public var clickProgress: Double?
    public var clickPosition: Vec2?
}

/// Precomputed, deterministic camera and cursor animation for a whole project.
///
/// Springs are stateful, so the track simulates the full timeline once, advancing them one
/// project frame at a time. Frames for any time (scrubbing, export) are interpolated between them.
public final class CameraTrack: @unchecked Sendable {
    public let layout: CanvasLayout
    public let durationMs: Double
    public let sampleIntervalMs: Double
    public static let clickRippleMs: Double = 450

    /// Scale of the cursor while a button is held.
    public static let pressedCursorScale = 0.9

    private let samples: [CameraFrame]
    private let clicks: [MouseEvent]
    private let typeEvents: [MouseEvent]
    private let cursorConfig: CursorConfig

    public init(project: Project, sampleRateHz: Double? = nil) {
        let layout = CanvasLayout(style: project.style, videoSize: project.recording.videoSize)
        self.layout = layout
        durationMs = max(project.recording.durationMs, 0)
        sampleIntervalMs = 1000 / (sampleRateHz ?? Double(max(project.recording.fps, 1)))

        let sorted = project.mouseEvents.sorted { $0.timeMs < $1.timeMs }
        let cleaned = MouseProcessing.removeSpikes(sorted, threshold: project.cursor.removeShakeThreshold)
        let sparse = MouseProcessing.downsample(cleaned, minDistance: 10 * project.recording.pointPixelScale)
        clicks = cleaned.filter { $0.kind == .down }
        cursorConfig = project.cursor
        let typeEvents = CursorTypes.typeEvents(cleaned, config: project.cursor)
        self.typeEvents = typeEvents
        let imageChanges = CursorTypes.imageChangeTimes(typeEvents, config: project.cursor)

        let planner = CameraPlanner(project: project, layout: layout, cleaned: cleaned, sparse: sparse)

        let duration = durationMs
        let cursorPath = CursorPathCache.shared.path(
            for: CursorPathCache.Key(
                events: cleaned,
                durationMs: duration,
                loopMs: project.cursor.loopPositionBeforeEndMs,
                stopMs: project.cursor.stopMovementInLastPartMs,
                spring: project.animation.mouseSpring,
                pointPixelScale: project.recording.pointPixelScale,
                imageChangesMs: imageChanges
            )
        ) {
            let pathPoints = Self.cursorPathPoints(events: cleaned, durationMs: duration, config: project.cursor)
            guard let endMs = pathPoints.last?.timeMs else { return nil }
            return SmoothedCursorPath.plan(
                points: pathPoints,
                syncPoints: Self.cursorSyncPoints(
                    events: cleaned.filter { $0.timeMs >= 0 && $0.timeMs <= endMs },
                    pointPixelScale: project.recording.pointPixelScale,
                    cursorImageChangesMs: imageChanges.filter { $0 >= 0 && $0 <= endMs }
                ),
                spring: project.animation.mouseSpring,
                durationMs: duration
            )
        }

        var screen = SpringRect(layout.restScreen)
        var press = SpringValue(1)
        let pressSpring = project.animation.mouseSpring ?? .instant
        let buttonEvents = cleaned.filter(\.isClick)
        var frames: [CameraFrame] = []
        let count = Int((durationMs / sampleIntervalMs).rounded(.up)) + 2
        frames.reserveCapacity(count)

        for i in 0..<count {
            let t = Double(i) * sampleIntervalMs
            let target = planner.target(at: t)
            let screenConfig = target.instant ? SpringConfig.instant : project.animation.screenSpring
            if i == 0 {
                if target.instant { screen = SpringRect(target.rect) }
            } else {
                screen.advance(toward: target.rect, config: screenConfig, milliseconds: sampleIntervalMs)
            }

            let pressed = CursorTypes.isPressed(at: t, events: cleaned, clicks: buttonEvents, smoothed: project.animation.mouseSpring != nil)
            press.setTarget(pressed ? Self.pressedCursorScale : 1, config: pressSpring)
            if i == 0 { press.snapToTarget() } else { press.advance(by: sampleIntervalMs, config: pressSpring) }

            var frame = CameraFrame(timeMs: t, screenRect: screen.rect, cursor: cursorPath?.position(at: t))
            frame.cursorScale = press.value
            frame.isInstantSnap = target.instant
            frame.cursorOpacity = Self.cursorOpacity(at: t, events: cleaned, hideAfterMs: project.cursor.hideNotMovingAfterMs)
            frames.append(frame)
        }
        samples = frames
    }

    /// The frame at `timeMs`, with the previous project frame attached for motion blur.
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
        frame.cursorName = CursorTypes.assetName(at: timeMs, typeEvents: typeEvents, config: cursorConfig)
        if let i = MouseProcessing.lastIndex(atOrBefore: timeMs, in: clicks) {
            let age = timeMs - clicks[i].timeMs
            if age >= 0 && age < Self.clickRippleMs {
                frame.clickProgress = age / Self.clickRippleMs
                frame.clickPosition = clicks[i].position
            }
        }
        return frame
    }

    /// Recorded positions the smoothed cursor follows: the first sample is moved to the start,
    /// and with "Loop cursor position" the path ends early and returns to the starting position 1
    /// ms after its last sample. "Stop cursor movement at the end of the video" ends the path
    /// early so the cursor holds still.
    public static func cursorPathPoints(events: [MouseEvent], durationMs: Double, config: CursorConfig) -> [CursorPathPoint] {
        var endMs = max(0, durationMs - (config.loopPositionBeforeEndMs ?? 0))
        if config.loopPositionBeforeEndMs == nil, config.stopMovementInLastPartMs > 0 {
            endMs = max(0, durationMs - config.stopMovementInLastPartMs)
        }
        var inRange = events.filter { $0.timeMs >= 0 && $0.timeMs <= endMs }
        if inRange.isEmpty {
            let before = MouseProcessing.lastIndex(atOrBefore: 0, in: events).map { events[$0] }
            if let fallback = before ?? events.first { inRange = [fallback] }
        }
        guard !inRange.isEmpty else { return [] }
        inRange[0].timeMs = 0
        var points = inRange.map { CursorPathPoint(timeMs: $0.timeMs, position: $0.position) }
        if config.loopPositionBeforeEndMs != nil, let first = points.first, let last = points.last {
            points.append(CursorPathPoint(timeMs: last.timeMs + 1, position: first.position))
        }
        return points
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

    /// Fades the cursor out 300 ms after it stopped moving for `hideAfterMs`.
    static func cursorOpacity(at t: Double, events: [MouseEvent], hideAfterMs: Double?) -> Double {
        guard let hideAfterMs, let i = MouseProcessing.lastIndex(atOrBefore: t, in: events) else { return 1 }
        let idle = t - events[i].timeMs
        guard idle > hideAfterMs else { return 1 }
        return clamp(1 - (idle - hideAfterMs) / 300, 0, 1)
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

/// Decides, for any instant, where the camera wants to be (before spring smoothing).
struct CameraPlanner {
    let project: Project
    let layout: CanvasLayout
    let cleaned: [MouseEvent]
    let zooms: [ZoomRange]
    let groups: [UUID: [FocusGroup]]

    init(project: Project, layout: CanvasLayout, cleaned: [MouseEvent], sparse: [MouseEvent]) {
        self.project = project
        self.layout = layout
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
    }

    func activeZoom(at t: Double) -> ZoomRange? {
        if let zoom = zooms.last(where: { $0.contains(t) }) { return zoom }
        let lead = project.animation.leadInMs
        if lead > 0, let next = zooms.first(where: { $0.startMs > t }), !next.isInstant, t >= next.startMs - lead {
            return next
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

    func isInInstantWindow(_ t: Double) -> Bool {
        zooms.contains { $0.isInstant && t >= $0.startMs && t <= $0.endMs + 50 }
    }

    func target(at t: Double) -> (rect: Rect2, instant: Bool) {
        let instant = isInInstantWindow(t)
        guard let zoom = activeZoom(at: t) else { return (layout.restScreen, instant) }
        let rect = ZoomGeometry.zoomedScreenRect(
            rest: layout.restScreen,
            scale: zoom.scale,
            focus: focus(for: zoom, at: t),
            area: layout.zoomArea
        )
        return (rect, instant)
    }
}

/// Planning the cursor is the expensive part of a track and does not depend on zooms or styles,
/// so the last result is reused while the inputs stay the same.
final class CursorPathCache: @unchecked Sendable {
    struct Key: Equatable {
        var events: [MouseEvent]
        var durationMs: Double
        var loopMs: Double?
        var stopMs: Double
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
