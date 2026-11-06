import Foundation

extension Project {
    /// The project without what the camera and cursor animation never reads (sound, captions,
    /// markers, processing, auto-zoom settings, save date): edits there keep the animation.
    var motionInputs: Project {
        var p = self
        p.audio = AudioConfig()
        p.captions = CaptionsConfig()
        p.markersMs = []
        p.lastSavedAt = nil
        p.processing = ProcessingConfig()
        p.autoZoom = AutoZoomConfig()
        return p
    }
}

/// Every spring of a track at one frame.
struct MotionSprings {
    var screen: SpringRect
    var cameraRect = SpringRect(Rect2(x: 0, y: 0, width: 0, height: 0))
    var cameraOpacity = SpringValue(0)
    var cameraRadius = SpringValue(0)
    var cameraReference = SpringValue(1)
    var mask: MaskAnimator
    var press = SpringValue(1)
    var opacity = SpringValue(1)
    var rotation = SpringValue(0)
    var fadeBlur = SpringValue(0)
    var focalX = SpringValue(0.5)
    var focalY = SpringValue(0.5)
    var cutout = SpringValue(0)
    var loupe = LoupeSpring(.none)
    var backdrop = BackdropSpring()
}

/// The emulated frames of a track: consecutive frames ending at the springs' frame.
struct MotionFrameWindow {
    private(set) var first = 0
    private(set) var frames: [CameraFrame] = []

    var isEmpty: Bool { frames.isEmpty }
    /// Frames held, as a range of frame numbers.
    var range: Range<Int> { first..<(first + frames.count) }

    subscript(frame: Int) -> CameraFrame? {
        range.contains(frame) ? frames[frame - first] : nil
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }

    /// Stores `value` as `frame`: the next after the last, the last again, or the first of an
    /// empty window.
    mutating func store(_ frame: Int, _ value: CameraFrame) {
        if frames.isEmpty {
            first = frame
            frames.append(value)
        } else if frame == first + frames.count {
            frames.append(value)
        } else if frame == first + frames.count - 1 {
            frames[frames.count - 1] = value
        } else {
            preconditionFailure("Frames are emulated in order")
        }
    }

    /// Drops the frames before `frame`.
    mutating func evict(before frame: Int) {
        let n = min(max(0, frame - first), frames.count)
        guard n > 0 else { return }
        frames.removeFirst(n)
        first += n
    }
}

/// What a track's animation reads, and its springs.
///
/// Frames are emulated on demand. A frame not emulated yet continues the springs when it is
/// at most 1 s after them; otherwise every spring starts at rest on its target 1 s earlier
/// (`influenceTime`) and the frames are emulated from there. Each emulation runs 30 frames
/// past the one asked for, stopping once that one is done and more than 1 ms went by. Frames
/// more than 2 s before the last time asked for are dropped. Idle time can emulate up to 50
/// frames past it. Every call runs under `lock`.
final class CameraMotion: @unchecked Sendable {
    /// Everything the animation reads.
    struct Key: Equatable, Sendable {
        var project: Project
        var faces: CameraFaces?
        var silence: [SilenceChunk]
        var hovers: CursorHovers?
        var fps: Double
    }

    /// How far back the springs start, and how far ahead of them they continue.
    static let influenceTimeMs = 1000.0
    /// Frames emulated past the one asked for.
    static let eagerFrames = 30
    /// Frames before the last time asked for that are kept.
    static let keptBehindMs = 2 * influenceTimeMs
    /// Emulation runs before the springs start over in idle time.
    static let maxEmulationRuns = 512
    /// Time an emulation may take once the frame asked for is done.
    static let eagerBudgetMs = 1.0
    /// Frames emulated ahead of the last time asked for in idle time.
    static let idlePrecomputeFrames = 50
    /// Time each idle step needs left.
    static let idleStepMs = 2.0

    let key: Key
    let lock = NSLock()

    let layout: CanvasLayout
    let durationMs: Double
    let frameDurationMs: Double
    /// The last frame of the playback duration (one past its end, plus one).
    let lastFrame: Int
    let resolver: TimeResolver
    let planner: CameraPlanner
    /// The screen-only layout of the plain stage.
    let plainResolver: LayoutResolver
    /// Presses of the drawn cursor's events.
    let clicks: [MouseEvent]
    let typeEvents: [MouseEvent]
    /// Image names of `typeEvents`, index for index.
    let typeEventNames: [String]
    let cursorConfig: CursorConfig
    /// Cursor position at the start, for frames without one.
    let firstCursor: Vec2?

    private let project: Project
    private let cursorPlan: CursorPlan
    private let pathEvents: [MouseEvent]
    private let buttonEvents: [MouseEvent]
    private let sorted: [MouseEvent]
    private let sliceLookup: SliceLookup
    private let hasCamera: Bool
    private let confidentFaces: [CameraFaceSample]?
    private let rotationSpring: SpringConfig
    private let baseRotationRad: Double
    /// The canvas in stage units.
    private let stage: Rect2
    private let initialScreen: Rect2

    /// Time an emulation may take once the frame asked for is done; nil = no limit.
    var budgetMs: Double? = CameraMotion.eagerBudgetMs

    private var springs: MotionSprings?
    /// The frame the springs are at, and its values.
    private(set) var springFrame = 0
    private var current: CameraFrame?
    private(set) var window = MotionFrameWindow()
    private var lastRequestedTimeMs = Double.nan
    private(set) var lastRequestedFrame = 0
    private var hasRequest = false
    /// Emulation runs since the springs last started over.
    private(set) var emulationRuns = 0
    /// Times the springs started over, for tests.
    private(set) var resets = 0

    init(key: Key) {
        self.key = key
        // Everything below works in the crop's space.
        let project = key.project.screenCropSpace
        self.project = project
        let layout = CanvasLayout(project: project)
        self.layout = layout
        let timeline = LayoutTimeline(project: project)
        let resolver = project.resolver
        self.resolver = resolver
        durationMs = max(resolver.playbackDurationMs, 0)
        frameDurationMs = 1000 / max(key.fps, 1)
        lastFrame = Int((durationMs / frameDurationMs).rounded(.up)) + 1

        let sorted = project.mouseEvents.sorted { $0.timeMs < $1.timeMs }
        self.sorted = sorted
        let cleaned = MouseProcessing.removeShakes(sorted, threshold: project.cursor.removeShakeThreshold)
        cursorConfig = project.cursor
        let typeEvents = CursorTypes.typeEvents(cleaned, config: project.cursor)
        self.typeEvents = typeEvents
        let typeEventNames = project.cursor.alwaysUseDefault ? [] : CursorTypes.assetNames(of: typeEvents)
        self.typeEventNames = typeEventNames
        let imageChanges = CursorTypes.imageChangeTimes(typeEvents, names: typeEventNames, config: project.cursor)
        let pathEvents = CameraTrack.cursorPathEvents(events: cleaned, resolver: resolver, config: project.cursor)
        self.pathEvents = pathEvents
        clicks = pathEvents.filter { $0.kind == .down }
        buttonEvents = pathEvents.filter(\.isClick)
        let hoverTimes = project.cursorHoverTimes(key.hovers)

        planner = CameraPlanner(project: project, timeline: timeline, cleaned: cleaned, pathEvents: pathEvents, silence: key.silence)
        plainResolver = project.plainLayoutResolver

        cursorPlan = CursorPathCache.shared.plan(for: CursorPlan.Inputs(
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
        firstCursor = cursorPlan.position(at: 0)
        initialScreen = timeline.defaultResolver.initialScreenRect
        hasCamera = project.recording.hasCamera && !project.camera.hide
        rotationSpring = CursorRotation.spring(for: project.cursor.rotationMode)
        baseRotationRad = project.cursor.baseRotation * .pi / 180
        // Face tracking: the focal point always uses its own spring.
        confidentFaces = project.camera.enableFaceTracking ? FaceTracking.confident(key.faces) : nil
        stage = Rect2(x: 0, y: 0, width: layout.canvas.width / layout.scale, height: layout.canvas.height / layout.scale)
        sliceLookup = SliceLookup(slices: project.slices)
    }

    // MARK: Frames and times

    /// Snaps values within 1e-7 of a whole number to it.
    static func snapped(_ x: Double) -> Double {
        let r = x.rounded()
        return abs(r - x) < 1e-7 ? r : x
    }

    /// Frame number of `timeMs`, fractional.
    func fractionalFrame(_ timeMs: Double) -> Double { Self.snapped(timeMs / frameDurationMs) }

    /// The frame `timeMs` falls in.
    func frameIndex(_ timeMs: Double) -> Int { Int(fractionalFrame(timeMs).rounded(.down)) }

    /// Start of `frame`.
    func frameTime(_ frame: Int) -> Double { Self.snapped(frameDurationMs * Double(frame)) }

    private var springTimeMs: Double { frameTime(springFrame) }

    // MARK: Requests

    /// A new time asked for: frames more than 2 s before it are dropped.
    func trackRequest(_ timeMs: Double) {
        guard timeMs != lastRequestedTimeMs else { return }
        lastRequestedTimeMs = timeMs
        lastRequestedFrame = max(0, frameIndex(timeMs))
        hasRequest = true
        let cutoff = lastRequestedFrame - Int((Self.keptBehindMs / frameDurationMs).rounded(.up))
        if cutoff > 0 { window.evict(before: cutoff) }
    }

    /// The values of `frame`, emulated when not held.
    func style(frame: Int) -> CameraFrame {
        if let held = window[frame] { return held }
        let value = emulate(forTimeMs: frameTime(frame))
        emulationRuns += 1
        return value
    }

    /// Starts every spring at rest on its targets at the frame `timeMs` falls in (0 at most).
    private func resetSprings(atTimeMs timeMs: Double) {
        resets += 1
        let frame = frameIndex(max(0, timeMs))
        var s = freshSprings()
        let value = step(frame, &s, reset: true)
        springs = s
        springFrame = frame
        current = value
        window.removeAll()
        window.store(frame, value)
        emulationRuns = 0
    }

    /// Emulates through the frame `timeMs` falls in and up to 30 past it.
    private func emulate(forTimeMs timeMs: Double) -> CameraFrame {
        precondition(timeMs >= 0, "Cannot emulate for negative time")
        let start = DispatchTime.now().uptimeNanoseconds
        if springs == nil || timeMs < springTimeMs || timeMs > springTimeMs + Self.influenceTimeMs {
            resetSprings(atTimeMs: timeMs - Self.influenceTimeMs)
        }
        let target = frameIndex(timeMs)
        let end = frameIndex(timeMs + frameDurationMs * Double(Self.eagerFrames))
        precondition(end - springFrame >= 0 && end - springFrame <= 10_000, "Frames to emulate out of range")
        guard var s = springs, var value = current else { preconditionFailure("Springs are not initialized") }
        window.store(springFrame, value)
        var result: CameraFrame? = springFrame == target ? value : nil
        while springFrame < end {
            springFrame += 1
            value = step(springFrame, &s, reset: false)
            window.store(springFrame, value)
            if springFrame == target { result = value }
            if springFrame >= target, let budgetMs, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 > budgetMs { break }
        }
        springs = s
        current = value
        guard let result else { preconditionFailure("Frame was not emulated") }
        return result
    }

    // MARK: Idle work

    var hasIdlePrecomputeWork: Bool {
        guard springs != nil, hasRequest else { return false }
        return springFrame < lastRequestedFrame + Self.idlePrecomputeFrames
    }

    /// One idle step: after 512 emulation runs the springs start over at the last time asked
    /// for; then frames are emulated ahead while `shouldStartWork` grants 2 ms more.
    func stepIdlePrecompute(shouldStartWork: (Double) -> Bool) {
        if emulationRuns >= Self.maxEmulationRuns {
            springs = nil
            current = nil
            window.removeAll()
            emulationRuns = 0
            if hasRequest {
                _ = emulate(forTimeMs: max(0, lastRequestedTimeMs))
                emulationRuns += 1
            }
        }
        guard hasIdlePrecomputeWork, var s = springs else { return }
        let end = lastRequestedFrame + Self.idlePrecomputeFrames
        var value = current
        while springFrame < end, shouldStartWork(Self.idleStepMs) {
            springFrame += 1
            let next = step(springFrame, &s, reset: false)
            window.store(springFrame, next)
            value = next
        }
        springs = s
        current = value
        emulationRuns += 1
    }

    // MARK: One frame

    func freshSprings() -> MotionSprings {
        MotionSprings(screen: SpringRect(initialScreen), mask: MaskAnimator(masks: project.masks, recordingSize: project.recording.videoSize))
    }

    /// Frames `first` through `last` with every spring starting at rest on its targets at
    /// `first`, outside the held frames.
    func emulatedFrames(from first: Int, through last: Int) -> [CameraFrame] {
        var s = freshSprings()
        return (first...last).map { step($0, &s, reset: $0 == first) }
    }

    /// Advances every spring to `i`, or with `reset` starts them at rest on its targets.
    func step(_ i: Int, _ s: inout MotionSprings, reset: Bool) -> CameraFrame {
        let dt = frameDurationMs
        let t = frameTime(i)
        let source = resolver.playbackToSource(t)
        let slice = sliceLookup.slice(atSource: source)
        let loupeTarget = planner.loupeTarget(at: source)
        let target = planner.targets(at: source, loupe: loupeTarget)
        let screenConfig = target.instant ? SpringConfig.instant : project.animation.screenSpring
        if reset {
            s.screen = SpringRect(target.screen)
        } else {
            s.screen.advance(toward: target.screen, config: screenConfig, milliseconds: dt)
        }

        // Camera: the fast spring while hidden and when it was hidden 200 ms before.
        let recentlyHidden = target.cameraHidden || planner.isCameraHidden(at: source - 200)
        let cameraConfig = recentlyHidden ? CameraTrack.cameraHideSpring : project.animation.screenSpring
        if hasCamera, let rect = target.camera {
            if reset || s.cameraRect.rect.width == 0 {
                s.cameraRect = SpringRect(rect)
                s.cameraRadius = SpringValue(target.cameraBorderRadius)
                s.cameraReference = SpringValue(target.cameraReferenceWidth)
                s.cutout = SpringValue(target.cameraCutout ? 1 : 0)
                if reset { s.cameraOpacity = SpringValue(target.cameraOpacity) }
            } else {
                s.cameraRect.advance(toward: rect, config: cameraConfig, milliseconds: dt)
                s.cameraRadius.advance(toward: target.cameraBorderRadius, config: cameraConfig, milliseconds: dt)
                s.cameraReference.advance(toward: target.cameraReferenceWidth, config: cameraConfig, milliseconds: dt)
            }
            if !reset {
                s.cameraOpacity.advance(toward: target.cameraOpacity, config: cameraConfig, milliseconds: dt)
                s.cutout.advance(toward: target.cameraCutout ? 1 : 0, config: cameraConfig, milliseconds: dt)
            }
        } else if hasCamera {
            s.cameraOpacity.advance(toward: 0, config: cameraConfig, milliseconds: dt)
        }

        // Press scale (`pressSpring`): instant without smooth movement or in clips without it.
        let smooth = project.animation.mouseSpring != nil
        let pressSpring = !smooth || slice?.disableSmoothMouseMovement == true ? SpringConfig.instant : project.animation.mouseSpring!
        let pressed = CursorTypes.isPressed(at: source, events: pathEvents, clicks: buttonEvents, smoothed: smooth)
        s.press.setTarget(pressed ? CameraTrack.pressedCursorScale : 1, config: pressSpring)
        if reset { s.press.snapToTarget() } else { s.press.advance(by: dt, config: pressSpring) }

        var frame = CameraFrame(timeMs: t, screenRect: layout.toCanvas(s.screen.rect), cursor: cursorPlan.position(at: t))
        // The lens springs on its own (`styles.loupe`).
        if reset { s.loupe = LoupeSpring(loupeTarget.frame) } else { s.loupe.advance(toward: loupeTarget.frame, config: planner.loupeSpring(at: source), milliseconds: dt) }
        let lens = s.loupe.frame
        frame.loupe = lens.isVisible(recordingWidth: project.recording.videoSize.width, k: 0.1) ? lens : nil
        s.backdrop.advance(toward: planner.backdropTarget(at: source, loupeActive: loupeTarget.isActive, stage: stage), config: project.animation.screenSpring, milliseconds: dt, first: reset)
        frame.backgroundRect = layout.toCanvas(s.backdrop.rect.rect)
        frame.backgroundBlurRadius = s.backdrop.blurRadius.value
        frame.frostBlurRadius = s.backdrop.frostBlurRadius.value
        frame.screenReferenceWidth = target.screenReferenceWidth * layout.scale
        frame.allowsScreenBorderRadius = target.allowsScreenBorderRadius
        frame.isBackgroundVisible = target.isBackgroundVisible
        if hasCamera, s.cameraRect.rect.width > 0 {
            let rect = s.cameraRect.rect
            frame.cameraRect = layout.toCanvas(rect)
            frame.cameraOpacity = clamp(s.cameraOpacity.value, 0, 1)
            frame.cameraSizeFactor = rect.width / max(s.cameraReference.value, 0.0001)
            frame.cameraCornerRadius = s.cameraRadius.value * frame.cameraSizeFactor * layout.scale
            frame.cameraCutout01 = clamp(s.cutout.value, 0, 1)
        }
        if hasCamera {
            var focal = FaceTracking.disabledCenter
            if project.camera.enableFaceTracking {
                focal = FaceTracking.faceCenter01(confident: confidentFaces, cameraTimeMs: source + project.camera.delayAdjustmentMs, crop01: project.camera.crop01)
            }
            if project.camera.mirror { focal.x = 1 - focal.x }
            s.focalX.setTarget(focal.x, config: FaceTracking.spring)
            s.focalY.setTarget(focal.y, config: FaceTracking.spring)
            if reset {
                s.focalX.snapToTarget()
                s.focalY.snapToTarget()
            } else {
                s.focalX.advance(by: dt, config: FaceTracking.spring)
                s.focalY.advance(by: dt, config: FaceTracking.spring)
            }
            frame.cameraFocal01 = Vec2(s.focalX.value, s.focalY.value)
        }
        frame.cursorScale = s.press.value
        frame.isInstantSnap = target.instant
        // Cursor opacity: fades out quickly while typing, otherwise follows visibility.
        let typing = Typing.isActivelyTyping(at: source, keystrokes: project.keystrokes, mouseEvents: sorted)
        let visible = slice?.hideCursor != true
            && CameraTrack.isCursorVisible(at: source, pathEvents: pathEvents, hideAfterMs: project.cursor.hideNotMovingAfterMs)
        let opacitySpring = typing ? CameraTrack.typingFadeSpring : CameraTrack.visibilitySpring
        s.opacity.setTarget(typing || !visible ? 0 : 1, config: opacitySpring)
        if reset { s.opacity.snapToTarget() } else { s.opacity.advance(by: dt, config: opacitySpring) }
        frame.cursorOpacity = s.opacity.value
        // Rotation: the base plus the motion rotation, sprung.
        s.rotation.setTarget(baseRotationRad + cursorPlan.motionRotation(at: t), config: rotationSpring)
        if reset { s.rotation.snapToTarget() } else { s.rotation.advance(by: dt, config: rotationSpring) }
        frame.cursorRotationRad = s.rotation.value
        // A fading cursor blurs toward 10 with the visibility spring; none when it is not drawn.
        if project.cursor.hide {
            s.fadeBlur = SpringValue(0)
        } else {
            s.fadeBlur.setTarget(typing || !visible ? CameraTrack.fadeOutBlurRadius : 0, config: CameraTrack.visibilitySpring)
            if reset { s.fadeBlur.snapToTarget() } else { s.fadeBlur.advance(by: dt, config: CameraTrack.visibilitySpring) }
        }
        frame.cursorFadeBlurRadius = s.fadeBlur.value
        frame.mask = s.mask.frame(at: source, stepMs: dt, first: reset)
        return frame
    }
}
