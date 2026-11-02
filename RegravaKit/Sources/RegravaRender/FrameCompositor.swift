import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RegravaCore

/// Builds one output frame: background, shadow, rounded screen with inset, click effect and cursor.
///
/// Inputs use top-left coordinates (like the rest of the project); Core Image uses
/// bottom-left, so every rectangle is flipped through `ciRect`.
public final class FrameCompositor: @unchecked Sendable {
    public let layout: CanvasLayout
    private let style: StyleConfig
    private let cursorConfig: CursorConfig
    private let pointPixelScale: Double
    private let cursors: CursorLibrary?
    /// The background, laid out and blurred per frame.
    private let backdrop: Backdrop
    private let motionBlurAmount: Double
    /// Rate frames are produced at (`playback.fps`).
    private let fps: Double
    private let camera: CameraConfig
    /// A cutout layout is used somewhere, so camera frames are matted (`isCameraMatted`).
    private let isCameraMatted: Bool
    /// Burned-in captions, drawn above everything.
    private let captions: CaptionRenderer?
    /// Keyboard shortcuts, the top-most layer.
    private let shortcuts: ShortcutRenderer?
    /// The device frame around an iPhone/iPad recording, when on.
    private let deviceFrame: ResolvedDeviceFrame?
    /// The recorded area kept (`cropWindow01`), 0…1 top-left.
    private let screenCrop01: Rect2
    /// Hide sensitive data / Hide faces: the scan's detections, drawn by source time.
    private let processing: ProcessingConfig
    private let sensitiveData: AutoMaskTimeline
    private let resolver: TimeResolver
    private let videoSize: Size2
    /// The colour grade already mixed with the identity by `lutIntensity`.
    private let cameraGrade: (data: Data, size: Int)?

    /// `assetsDirectory` is the project folder (for background images).
    public init(project: Project, layout: CanvasLayout, cursors: CursorLibrary?, assetsDirectory: URL? = nil, transcript: [TranscriptWord] = [], sensitiveData: [SensitiveDataDetection] = [], fps: Double = CameraTrack.previewFps) {
        processing = project.processing
        self.sensitiveData = AutoMaskTimeline(detections: project.processing.isAutoMasking ? sensitiveData.sorted { $0.startMs < $1.startMs } : [])
        resolver = project.resolver
        videoSize = project.recording.videoSize
        self.layout = layout
        style = project.style
        cursorConfig = project.cursor
        pointPixelScale = project.recording.pointPixelScale
        self.cursors = cursors
        motionBlurAmount = project.animation.motionBlurAmount
        self.fps = fps
        camera = project.camera
        isCameraMatted = project.isCutoutLayoutUsed
        captions = CaptionRenderer(project: project, words: transcript, canvas: layout.canvas, fps: fps)
        shortcuts = ShortcutRenderer(project: project, canvas: layout.canvas, captionsShown: captions != nil, fps: fps)
        cameraGrade = Self.loadGrade(project.camera, assetsDirectory: assetsDirectory)
        deviceFrame = project.activeDeviceFrame
        screenCrop01 = project.screenCrop01
        backdrop = Backdrop(project.style.background, layout: layout, assetsDirectory: assetsDirectory)
    }

    /// The background of `frame`: laid out over its rect and blurred (`backdrop.$sample`).
    /// Each placement is drawn once and kept while it repeats; a moving zoom draws new ones.
    private func background(_ frame: CameraFrame) -> CIImage {
        backdrop.image(bounds: frame.backgroundRect ?? layout.canvas, radius: frame.backgroundBlurRadius ?? backdrop.styleBlurRadius)
    }

    /// The loupe's frosted backdrop: the background read with the frost's extra blur, the two
    /// radii combined as √(blur² + frost²).
    private func frost(_ frame: CameraFrame) -> CIImage {
        let blur = frame.backgroundBlurRadius ?? backdrop.styleBlurRadius
        let frost = frame.frostBlurRadius ?? layout.canvas.width / max(layout.scale, 0.000001) * 0.005
        return backdrop.image(bounds: frame.backgroundRect ?? layout.canvas, radius: (blur * blur + frost * frost).squareRoot())
    }

    private var canvasHeight: Double { layout.canvas.height }

    /// Only the crop of the recording, moved to the origin (Core Image is y-up).
    private func cropped(_ image: CIImage) -> CIImage {
        guard screenCrop01 != Rect2(x: 0, y: 0, width: 1, height: 1) else { return image }
        let w = image.extent.width, h = image.extent.height
        let c = screenCrop01
        let rect = CGRect(x: c.x * w, y: (1 - c.y - c.height) * h, width: c.width * w, height: c.height * h).integral.intersection(image.extent)
        guard !rect.isEmpty else { return image }
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private func ciRect(_ r: Rect2) -> CGRect {
        CGRect(x: r.x, y: canvasHeight - r.y - r.height, width: r.width, height: r.height)
    }

    private func ciPoint(_ p: Vec2) -> CGPoint {
        CGPoint(x: p.x, y: canvasHeight - p.y)
    }

    /// Camera frames go through the person matte (a cutout layout is used).
    var mattesCamera: Bool { isCameraMatted }

    /// Trail strength of the screen and cursor while moving (0 = motion blur off).
    var motionBlurStrength: Double { MotionBlur.strength(amount: motionBlurAmount, fps: fps, disabled: false) }

    public func compose(source: CIImage, camera cameraImage: CIImage? = nil, frame: CameraFrame, quality: RenderQuality = .export) -> CIImage {
        let canvasRect = ciRect(layout.canvas)
        // The recording is debanded first (`screenDeband`), on the whole frame.
        let recording = Deband.apply(
            source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)),
            settings: Deband.recordingSettings(quality01: processing.improveRecordingQuality01, motionBlurAmount: motionBlurAmount, screen: frame.screenRect, before: frame.previousScreenRect, quality: quality)
        )
        // Masks act on the recording itself, so they follow zoom and motion blur. Their edge
        // is 1.5 output pixels wide, in recording pixels.
        let screenSource = cropped(recording)
        let videoPerCanvas = screenSource.extent.width / max(videoRect(inBody: frame.screenRect).width, 0.0001)
        var src = MaskRenderer.apply(frame.mask, to: screenSource, antialias: SmoothShapes.antialias * max(1, videoPerCanvas))
        // Auto masks after the manual one, never on the timeline.
        if !sensitiveData.isEmpty {
            let covers = AutoMasks.frame(at: resolver.playbackToSource(frame.timeMs), timeline: sensitiveData, config: processing, videoSize: videoSize)
            src = AutoMaskRenderer.apply(covers, to: src, crop01: screenCrop01, videoSize: videoSize)
        }
        // Click effects are part of the screen content: masks and motion blur carry them.
        src = clickEffects(on: src, frame: frame, quality: quality)
        // The webcam frame is matted, sharpened and graded once, for the stage and the loupe.
        let camera = cameraImage.map { image in PreparedCamera { self.preparedCamera(image, frame: frame, quality: quality) } }
        var output = session(over: background(frame), source: src, camera: camera, frame: frame, quality: quality)
        // The glass loupe over the whole session, camera and cursor included.
        if let lens = frame.loupe {
            output = loupe(lens, over: output, source: src, camera: camera, frame: frame, quality: quality)
        }
        if let captions { output = captions.draw(over: output, atPlayback: frame.timeMs, motionBlurStrength: motionBlurStrength, quality: quality) }
        if let shortcuts { output = shortcuts.draw(over: output, atPlayback: frame.timeMs, motionBlurStrength: motionBlurStrength, quality: quality) }

        return output.cropped(to: canvasRect)
    }

    /// Screen, cursor and camera over `base`, laid out through `perspective` (the loupe's
    /// magnification, identity on the stage).
    private func session(over base: CIImage, source src: CIImage, camera: PreparedCamera?, frame: CameraFrame, quality: RenderQuality, perspective: Perspective = .identity) -> CIImage {
        let strength = MotionBlur.strength(amount: motionBlurAmount, fps: fps, disabled: frame.isInstantSnap)

        // Screen trail: from lerp(now, before, strength) to now (`rf.trailStart`).
        let now = frame.screenRect
        let trailStart = strength > 0 ? now.lerp(to: frame.previousScreenRect ?? now, strength) : now
        let isStatic = strength == 0 || now.isClose(to: trailStart, tolerance: 1)

        var output = base
        if style.shadow.intensity > 0 {
            // One shadow at the trail's middle, under the inset and the content.
            let middle = isStatic ? now : trailStart.lerp(to: now, 0.5)
            let reference = frame.screenReferenceWidth > 0 ? frame.screenReferenceWidth : layout.restScreen.width
            // A device body casts it with its own smoothing, shrunk by its inset.
            let body = deviceFrame?.device
            output = partShadow(
                ciRect(middle), radius: screenRadius(middle, frame: frame), zoomFactor: middle.width / max(reference, 1), perspective: perspective,
                smoothing: body?.roundness ?? 1, inset: (body?.bodyInset ?? 0) * pointsToCanvas(middle)
            ).composited(over: output)
        }
        var screenImage = screenLayer(src, rect: now, frame: frame)
        if !isStatic {
            let bounds = ciRect(now).union(ciRect(trailStart)).integral
            let samples = MotionBlur.sampleCount(travel: now.cornerTravel(to: trailStart), quality: quality)
            // Every read is the layer at `now` moved and scaled into the trail's rect.
            if let blurred = MotionBlur.trail(screenImage, now: ciRect(now), start: ciRect(trailStart), samples: samples, bounds: bounds,
                                              canvasHeight: canvasHeight, falloffRatio: MotionBlur.screenFalloffRatio) {
                screenImage = blurred
            }
        }
        output = Self.dithered(screenImage).composited(over: output)

        let videoToCanvas = frame.screenRect.width / max(layout.videoSize.width, 1)

        if !cursorConfig.hide, frame.cursorOpacity > 0, let cursors, let position = frame.cursor {
            let cursor = cursors.asset(named: frame.cursorName)
            let tip = layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect)
            var tipBefore = tip
            if let previous = frame.previousCursor {
                tipBefore = layout.canvasPoint(videoPoint: previous, screenRect: frame.previousScreenRect ?? frame.screenRect)
            }
            let cursorStrength = motionBlurStrength
            let trailTip = tip.lerp(to: tipBefore, cursorStrength)
            let scaleNow = frame.cursorScale
            let trailScale = scaleNow + (frame.previousCursorScale - scaleNow) * cursorStrength
            let rotationNow = frame.cursorRotationRad
            let trailRotation = rotationNow + (frame.previousCursorRotationRad - rotationNow) * cursorStrength
            let travel = tip.distance(to: trailTip)
            // The visible cursor is `size` source pixels tall, times the press scale.
            let visibleHeight = cursorConfig.size * videoToCanvas
            var cursorImage = placedCursor(cursor, tip: tip, frame: frame, visibleHeight: visibleHeight * scaleNow, rotation: rotationNow)
            if cursorStrength > 0 && travel >= 1 {
                let bounds = cursorImage.extent
                    .union(placedCursor(cursor, tip: trailTip, frame: frame, visibleHeight: visibleHeight * trailScale, rotation: trailRotation).extent)
                    .integral
                if let blurred = MotionBlur.accumulate(samples: MotionBlur.sampleCount(travel: travel, quality: quality), bounds: bounds, layer: { t in
                    self.placedCursor(
                        cursor,
                        tip: trailTip.lerp(to: tip, t),
                        frame: frame,
                        visibleHeight: visibleHeight * (trailScale + (scaleNow - trailScale) * t),
                        rotation: trailRotation + (rotationNow - trailRotation) * t
                    )
                }) {
                    cursorImage = blurred
                }
            }
            output = cursorImage.composited(over: output)
        }

        // The webcam is drawn above everything.
        if let camera, let rect = frame.cameraRect, frame.cameraOpacity > 0.001, rect.width > 0.5, rect.height > 0.5 {
            output = cameraLayer(camera.image, rect: rect, frame: frame, quality: quality, perspective: perspective).composited(over: output)
        }
        return output
    }

    // MARK: Device frame

    /// The video rect inside the device body.
    func videoRect(inBody body: Rect2) -> Rect2 {
        guard let region = deviceFrame?.device.videoRegion01 else { return body }
        return Rect2(x: body.x + region.x * body.width, y: body.y + region.y * body.height, width: region.width * body.width, height: region.height * body.height)
    }

    /// `$sampleComposite`: the video stretched into the screen hole and clipped to a circular
    /// rounded rect of the device's screen radius, with the frame art drawn over it. Not
    /// clipped by the body's shape; the art's alpha gives the silhouette.
    private func deviceLayer(_ src: CIImage, body: Rect2, frame: ResolvedDeviceFrame) -> CIImage {
        let device = frame.device
        let hole = ciRect(videoRect(inBody: body))
        let video = src
            .transformed(by: CGAffineTransform(scaleX: hole.width / max(src.extent.width, 1), y: hole.height / max(src.extent.height, 1)))
            .transformed(by: CGAffineTransform(translationX: hole.minX, y: hole.minY))
        let r = min(device.screenRadius / max(device.screenWidth, 0.0001) * hole.width, min(hole.width, hole.height) / 2)
        var layer = SmoothShapes.clip(video, to: hole, radius: r, smoothing: 0)
        let bodyRect = ciRect(body)
        if let art = DeviceFrameArt.shared.image(for: frame.key, in: bodyRect) {
            layer = art.composited(over: layer)
        }
        return layer.cropped(to: bodyRect)
    }

    // MARK: Glass loupe

    private static let glassKernel = RenderKernels.general("loupeGlass")

    /// The session magnified around the lens centre, read through the glass over `scene`.
    private func loupe(_ lens: LoupeFrame, over scene: CIImage, source: CIImage, camera: PreparedCamera?, frame: CameraFrame, quality: RenderQuality) -> CIImage {
        guard let kernel = Self.glassKernel else { return scene }
        // The lens is placed over the video (inside a device frame's screen hole).
        let screen = videoRect(inBody: frame.screenRect)
        let w = screen.width
        guard lens.isVisible(recordingWidth: layout.videoSize.width, k: 1) else { return scene }
        let canvasRect = ciRect(layout.canvas)
        // Lens geometry in canvas pixels: centre through the screen rect, radius in screen widths.
        let center = Vec2(screen.x + lens.center.x * screen.width, screen.y + lens.center.y * screen.height)
        let radius = max(0, lens.radius) * w
        let zoom = max(lens.zoom, 0.05)

        // Content: screen, cursor and camera laid out through `magnify(center, zoom)`, the
        // camera fading by 1 − presence (`cameraOpacityFactor`).
        func magnify(_ r: Rect2) -> Rect2 {
            Rect2(x: center.x + (r.x - center.x) * zoom, y: center.y + (r.y - center.y) * zoom, width: r.width * zoom, height: r.height * zoom)
        }
        var inner = frame
        inner.screenRect = magnify(frame.screenRect)
        inner.previousScreenRect = frame.previousScreenRect.map(magnify)
        inner.cameraRect = frame.cameraRect.map(magnify)
        inner.previousCameraRect = frame.previousCameraRect.map(magnify)
        inner.cameraCornerRadius *= zoom
        inner.cameraSizeFactor *= zoom
        inner.cameraOpacity *= clamp(1 - lens.presence, 0, 1)
        let perspective = Perspective(center: ciPoint(center), scale: zoom)
        let clear = CIImage(color: .clear).cropped(to: canvasRect)
        let content = session(over: clear, source: source, camera: camera, frame: inner, quality: quality, perspective: perspective).cropped(to: canvasRect)
        // Blurrier reads on the compressed rim: lod 1…4, 0.58·(2^lod − 1) texels.
        let levels = (1...4).map { lod in content.applyingGaussianBlur(sigma: 0.58 * (pow(2, Double(lod)) - 1) * 0.5).cropped(to: canvasRect) }

        // Light from the screen shadow's light.
        let canvas = layout.canvas
        let a = style.shadow.angle * .pi / 180
        let reach = 1.5 * hypot(canvas.width / 2, canvas.height / 2)
        let light = Vec2(canvas.width / 2 - cos(a) * reach, canvas.height / 2 - sin(a) * reach)
        let toLight = Vec2(light.x - center.x, light.y - center.y)
        let dist = hypot(toLight.x, toLight.y)
        let direction = dist < 0.001 ? Vec2(0, -1) : Vec2(toLight.x / dist, toLight.y / dist)
        let shineExponent = clamp(dist / (0.1 * w), 1.5, 24)
        let lightTilt = min(dist / max(canvas.width, canvas.height), 2)
        let maxReads: Double = quality == .export || quality == .pausedHigh ? 16 : 4
        let c = ciPoint(center)

        // What each input is read over. Past the lens and its shadow only `scene` is read, at
        // the pixel itself. Inside, the view reads back by up to the bevel bend (≤ 2·bevel) plus
        // the fringe (≤ 0.35 of it) and the rim reflection up to two radii out; the cached frost
        // is read whole. Two pixels of margin for linear sampling;
        // boxes snap to 64 px and stay on the canvas, where reads past its edge clamp.
        let bevel = radius * clamp(lens.bevelRatio, 0, 1)
        func around(_ reach: Double) -> CGRect {
            let a = 64.0
            let x0 = floor((c.x - reach) / a) * a, y0 = floor((c.y - reach) / a) * a
            let x1 = ceil((c.x + reach) / a) * a, y1 = ceil((c.y + reach) / a) * a
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(canvasRect)
        }
        let lensBox = around(radius + LoupeFrame.shadowSize * w + 1.5 + 2)
        let viewBox = around(max(radius, 2 * bevel) + 0.7 * bevel + 2)
        let rimBox = around(2 * radius + 1 + 2)

        return kernel.apply(
            extent: canvasRect,
            roiCallback: { index, rect in
                guard rect.intersects(lensBox) else { return index == 5 ? rect : .null }
                switch index {
                case 5: return rect.union(rimBox).intersection(canvasRect)
                // The frost is cached whole, so it is drawn once for every lens position.
                case 6: return canvasRect
                default: return viewBox
                }
            },
            arguments: [
                content, levels[0], levels[1], levels[2], levels[3], scene.cropped(to: canvasRect), frost(frame),
                CIVector(x: c.x, y: c.y, z: radius, w: radius * clamp(lens.bevelRatio, 0, 1)),
                CIVector(x: zoom, y: clamp(lens.chromaticAberration, 0, 1), z: clamp(lens.presence, 0, 1), w: clamp(lens.shadowAlpha, 0, 1)),
                CIVector(x: direction.x, y: -direction.y, z: shineExponent, w: lightTilt),
                CIVector(x: LoupeFrame.shadowSize * w, y: maxReads, z: 0, w: 0),
            ]
        ) ?? scene
    }

    /// Recording points to canvas pixels at `rect`'s width (`sourcePixelScale × k`).
    private func pointsToCanvas(_ rect: Rect2) -> Double {
        // With a device frame the screen rect is the body, measured in device points.
        if let device = deviceFrame?.device { return rect.width / max(device.width, 0.0001) }
        return rect.width / max(layout.videoSize.width / max(pointPixelScale, 0.0001), 1)
    }

    /// `screenBorderRadius` in points, scaled with the drawn screen; 0 without padding or when
    /// the active layout disallows it.
    private func screenRadius(_ rect: Rect2, frame: CameraFrame) -> Double {
        // A device body's radius, whatever the padding or layout.
        if let device = deviceFrame?.device { return device.bodyRadius * pointsToCanvas(rect) }
        guard frame.allowsScreenBorderRadius, style.paddingRatio > 0 else { return 0 }
        return style.cornerRadius * pointsToCanvas(rect)
    }

    /// The recording placed into `rect` with smooth corners, the inset band behind it.
    private func screenLayer(_ src: CIImage, rect: Rect2, frame: CameraFrame) -> CIImage {
        let screen = ciRect(rect)
        let radius = screenRadius(rect, frame: frame)
        var image: CIImage
        if let deviceFrame {
            image = deviceLayer(src, body: rect, frame: deviceFrame)
        } else {
            let scaled = src
                .transformed(by: CGAffineTransform(scaleX: screen.width / max(src.extent.width, 1), y: screen.height / max(src.extent.height, 1)))
                .transformed(by: CGAffineTransform(translationX: screen.minX, y: screen.minY))
            image = SmoothShapes.clip(scaled, to: screen, radius: radius)
        }

        // Inset: a band outside the screen, behind it, only while the background shows.
        if style.inset.isOn, frame.isBackgroundVisible {
            let band = SmoothShapes.insetBand(screen, radius: radius, size: style.inset.size * pointsToCanvas(rect), origin01: style.inset.origin01, color: Self.ciColor(style.inset.color, alpha: style.inset.alpha))
            image = image.composited(over: band)
        }
        return image
    }

    /// A webcam frame drawn once per `compose`, however many sessions show it.
    private final class PreparedCamera {
        private let make: () -> CIImage
        private(set) lazy var image = make()
        init(_ make: @escaping () -> CIImage) { self.make = make }
    }

    /// The webcam frame matted, sharpened, graded, cropped and mirrored, at footage scale.
    private func preparedCamera(_ image: CIImage, frame: CameraFrame, quality: RenderQuality) -> CIImage {
        var content = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Cutout: the person matte goes first, before sharpen and the grade.
        if isCameraMatted, frame.cameraCutout01 > 0.001, let matte = PersonMatter.shared.matte(for: content, quality: quality) {
            let fullSize = content.extent.size
            content = CameraCutout.apply(frame: content, matte: matte, edge: camera.background, reveal01: 1 - frame.cameraCutout01, crop01: camera.crop01, density: quality == .playing ? 0.5 : 1)
            // Back to footage size so the crop window keeps its meaning.
            if content.extent.size != fullSize {
                content = content.transformed(by: CGAffineTransform(scaleX: fullSize.width / content.extent.width, y: fullSize.height / content.extent.height))
            }
        }
        content = Self.sharpened(content, amount: camera.sharpen01)
        content = graded(content)
        if let crop = camera.crop01 {
            let e = content.extent
            let window = CGRect(x: crop.x * e.width, y: (1 - crop.y - crop.height) * e.height, width: crop.width * e.width, height: crop.height * e.height)
            content = content.cropped(to: window).transformed(by: CGAffineTransform(translationX: -window.minX, y: -window.minY))
        }
        if camera.mirror {
            content = content.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -content.extent.width, y: 0))
        }
        return content
    }

    /// The webcam covering `rect` (centred focal point), cropped, mirrored, with rounded corners,
    /// the screen's shadow, and faded and blurred while hiding.
    private func cameraLayer(_ content: CIImage, rect: Rect2, frame: CameraFrame, quality: RenderQuality, perspective: Perspective = .identity) -> CIImage {
        // Only position and size trail; radius, focal point, cutout and shadow keep their
        // current values.
        let now = ciRect(rect)
        let radius = min(frame.cameraCornerRadius, min(now.width, now.height) / 2)
        func placedLayer(_ r: Rect2) -> CIImage {
            let target = ciRect(r)
            let size = content.extent.size
            let k = max(target.width / max(size.width, 1), target.height / max(size.height, 1))
            let w = size.width * k, h = size.height * k
            // Cover fill with the focal point at the frame centre, clamped to cover it.
            let x = FaceTracking.focalAxis(imageOrigin: r.x + (r.width - w) / 2, imageLength: w, frameOrigin: r.x, frameLength: r.width, focal01: frame.cameraFocal01.x)
            let yTop = FaceTracking.focalAxis(imageOrigin: r.y + (r.height - h) / 2, imageLength: h, frameOrigin: r.y, frameLength: r.height, focal01: frame.cameraFocal01.y)
            let placed = content
                .transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: x, y: canvasHeight - yTop - h))
            var layer = SmoothShapes.clip(placed.cropped(to: target), to: target, radius: radius)
            if style.shadow.intensity > 0 {
                // Rectangle shadow blended with the person's silhouette by cutout01 (`silhouette01`).
                let c = frame.cameraCutout01
                var cast = partShadow(target, radius: radius, zoomFactor: frame.cameraSizeFactor, perspective: perspective)
                if c > 0.001 {
                    let silhouette = silhouetteShadow(of: placed, caster: target, radius: radius, zoomFactor: frame.cameraSizeFactor, perspective: perspective)
                    cast = c >= 0.999 ? silhouette : Self.scaled(silhouette, c).composited(over: Self.scaled(cast, 1 - c))
                }
                layer = layer.composited(over: cast)
            }
            return layer
        }
        var layer = placedLayer(rect)
        // The trail from lerp(now, before, strength) to now; instant zoom snaps don't turn it off.
        let strength = motionBlurStrength
        var trailPx = 0.0
        if strength > 0, let before = frame.previousCameraRect {
            let trailStart = rect.lerp(to: before, strength)
            if !rect.isClose(to: trailStart, tolerance: 1) {
                trailPx = rect.cornerTravel(to: trailStart)
                let reach = style.shadow.intensity > 0 ? (style.shadow.blur * 8 * frame.cameraSizeFactor + style.shadow.distance * 6 + 16) * layout.scale + 8 : 8
                let bounds = now.union(ciRect(trailStart)).insetBy(dx: -reach, dy: -reach).integral
                let samples = MotionBlur.sampleCount(travel: trailPx, quality: quality)
                if let blurred = MotionBlur.accumulate(samples: samples, bounds: bounds, layer: { t in placedLayer(trailStart.lerp(to: rect, t)) }) {
                    layer = blurred
                }
            }
        }
        let opacity = frame.cameraOpacity
        if opacity < 1 {
            let blur = 10 * (1 - opacity) * layout.scale
            if blur > 0.1 { layer = layer.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: layer.extent.insetBy(dx: -3 * blur, dy: -3 * blur)) }
            layer = layer.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
            ])
        }
        return grained(layer, timeMs: frame.timeMs, trailPx: trailPx)
    }

    private static let grainKernel = RenderKernels.color("filmGrain")

    /// `cameraConfig.grain` after the trail and the opacity: weaker along a trail (÷ √trail px),
    /// seeded at 24 Hz over 1024 frames. No UI sets it in 4.1; it shows only for projects that
    /// carry a value.
    private func grained(_ layer: CIImage, timeMs: Double, trailPx: Double) -> CIImage {
        let intensity = camera.grain / sqrt(max(trailPx, 1))
        guard intensity >= 0.001, let kernel = Self.grainKernel else { return Self.dithered(layer) }
        let seed = Double(((Int(floor(timeMs * 24 / 1000)) % 1024) + 1024) % 1024)
        return Self.dithered(kernel.apply(extent: layer.extent, arguments: [layer, CIVector(x: intensity, y: seed, z: 0, w: 0)]) ?? layer)
    }

    private static let ditherKernel = RenderKernels.color("antiBandingDither")

    /// The anti-banding dither every rect part and gradient gets (`$ditherColor`): half a 1/255
    /// step of 8×8 Bayer noise at the output pixel, scaled by alpha.
    static func dithered(_ image: CIImage) -> CIImage {
        guard let kernel = ditherKernel, !image.extent.isInfinite else { return image }
        return kernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    private static let sharpenKernel = RenderKernels.general("casSharpen")

    /// Camera sharpen on the whole, uncropped frame before the colour grade. Frames are always decoded
    /// at full size.
    static func sharpened(_ image: CIImage, amount: Double) -> CIImage {
        let amount = clamp(amount, 0, 1)
        guard amount > 0, let kernel = sharpenKernel else { return image }
        let extent = image.extent
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
            arguments: [image.clampedToExtent(), Float(amount)]
        )?.cropped(to: extent) ?? image
    }

    /// The `.cube` asset as Core Image cube data. Mixing `straight` and `lut(straight)` by the
    /// intensity on sRGB-encoded values: trilinear lookup of a cube mixed with the identity gives
    /// the same result, so the mix is baked in.
    static func loadGrade(_ camera: CameraConfig, assetsDirectory: URL?) -> (data: Data, size: Int)? {
        let intensity = min(max(camera.lutIntensity, 0), 1)
        guard intensity >= 0.001, let name = camera.lut, let bundle = assetsDirectory,
              let text = try? String(contentsOf: ProjectStore.assetsURL(bundle: bundle).appendingPathComponent(name), encoding: .utf8),
              let lut = try? ColorLUT(cube: text) else { return nil }
        return (ColorGradeFilter.cubeData(lut, intensity: intensity), lut.size)
    }

    /// Grade after sharpening, before cropping (`[cameraSharpen, cameraLutGrade]`).
    private func graded(_ image: CIImage) -> CIImage {
        guard let cameraGrade else { return image }
        return ColorGradeFilter.apply(data: cameraGrade.data, size: cameraGrade.size, to: image)
    }

    // MARK: Pieces

    /// `resolvedShadowOptions` offset: `polar(angle, distance)` in stage units, 0° right and
    /// 90° down, not scaled by zoom; here in Core Image pixels (y up).
    private var shadowOffset: CGVector {
        let s = style.shadow
        let a = s.angle * .pi / 180
        return CGVector(dx: s.distance * cos(a) * layout.scale, dy: -s.distance * sin(a) * layout.scale)
    }

    /// Points move to `center + (p − center)·scale`; shadow offsets scale and the shadow light
    /// moves with it. Core Image coordinates.
    struct Perspective {
        var center: CGPoint
        var scale: Double
        static let identity = Perspective(center: .zero, scale: 1)

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: center.x + (p.x - center.x) * scale, y: center.y + (p.y - center.y) * scale)
        }
    }

    /// The Directional shadow's light: stage centre − polar(angle, 1.5 × |stage / 2|), y down,
    /// fixed on the stage; Core Image coordinates.
    private func shadowLight(_ perspective: Perspective) -> CGPoint {
        let canvas = layout.canvas
        let a = style.shadow.angle * .pi / 180
        let reach = 1.5 * hypot(canvas.width / 2, canvas.height / 2)
        return perspective.point(CGPoint(x: canvas.width / 2 - cos(a) * reach, y: canvas.height - (canvas.height / 2 - sin(a) * reach)))
    }

    /// The screen's or the camera's shadow: black at the intensity, blur `blur × 8 × k`;
    /// Directional marches toward a light fixed on the stage.
    private func partShadow(_ rect: CGRect, radius: Double, zoomFactor k: Double, perspective: Perspective = .identity, smoothing: Double = 1, inset: Double = 0) -> CIImage {
        let s = style.shadow
        let unit = layout.scale
        let blur = s.blur * 8 * k * unit
        let offset = CGVector(dx: shadowOffset.dx * perspective.scale, dy: shadowOffset.dy * perspective.scale)
        var directional: (light: CGPoint, radius: Double, falloff: Double)?
        if s.isDirectional {
            directional = (shadowLight(perspective), max(blur * 2.5, 4 * unit), max(hypot(offset.dx, offset.dy) * 6, 40 * unit))
        }
        return SmoothShapes.shadow(rect, radius: radius, .init(alpha: s.intensity, blur: blur, offset: offset, directional: directional, unit: unit, smoothing: smoothing, inset: inset))
    }

    /// The shadow cast by the camera's own alpha (`getContentShadowMask`), with the screen
    /// shadow's alpha, offset and light. `content` is the placed frame before its shape clips
    /// it; `caster` and `radius` are that shape.
    private func silhouetteShadow(of content: CIImage, caster: CGRect, radius: Double, zoomFactor: Double, perspective: Perspective = .identity) -> CIImage {
        let s = style.shadow
        let unit = layout.scale
        let blur = s.blur * 8 * zoomFactor * unit
        let offset = CGVector(dx: shadowOffset.dx * perspective.scale, dy: shadowOffset.dy * perspective.scale)
        var directional: (light: CGPoint, radius: Double, falloff: Double)?
        if s.isDirectional {
            directional = (shadowLight(perspective), max(blur * 2.5, 4 * unit), max(hypot(offset.dx, offset.dy) * 6, 40 * unit))
        }
        return SmoothShapes.contentShadow(content, caster: caster, radius: radius, .init(alpha: s.intensity, blur: blur, offset: offset, directional: directional, unit: unit))
    }

    private static func scaled(_ image: CIImage, _ k: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(k), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(k), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(k), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(k)),
        ])
    }

    /// The cursor drawn with its hotspot at `tip` (canvas pixels).
    private func placedCursor(_ cursor: CursorAsset, tip: Vec2, frame: CameraFrame, visibleHeight: Double, rotation: Double) -> CIImage {
        let target = ciRect(cursor.rect(tip: tip, visibleHeight: visibleHeight))
        let image = cursor.image
        var placed = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        // A fading cursor is blurred by its sprung radius (stage units, σ = radius / 2).
        let blurSigma = frame.cursorFadeBlurRadius * 0.5 * layout.scale
        if blurSigma > 0.01 {
            let extent = placed.extent
            placed = placed.applyingGaussianBlur(sigma: blurSigma).cropped(to: extent.insetBy(dx: -3 * blurSigma, dy: -3 * blurSigma))
        }
        if rotation != 0 {
            // Rotate around the hotspot; positive = clockwise.
            let pivot = ciPoint(tip)
            let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .rotated(by: -rotation)
                .translatedBy(x: -pivot.x, y: -pivot.y)
            placed = placed.transformed(by: transform)
        }
        if frame.cursorOpacity < 1 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(frame.cursorOpacity)),
            ])
        }
        return placed
    }

    // MARK: Click effects

    private static let clickKernel = RenderKernels.general("clickEffects")

    /// The click effect drawn into the recording `src` (crop space, origin at zero): up to three
    /// presses, sized by the recording's width, antialiased over 1.5 output pixels.
    private func clickEffects(on src: CIImage, frame: CameraFrame, quality: RenderQuality) -> CIImage {
        guard let effect = cursorConfig.clickEffect, !frame.clicks.isEmpty, let kernel = Self.clickKernel else { return src }
        let extent = src.extent
        guard extent.width > 0, extent.height > 0 else { return src }
        // Recording pixels to pixels of `src`.
        let k = extent.width / max(layout.videoSize.width, 1)
        let videoWidth = videoSize.width * k
        let knobs = ClickEffects.knobs(effect, videoWidth: videoWidth)
        var points: [CIVector] = []
        var states: [CIVector] = []
        for i in 0..<ClickEffects.maxClicks {
            if i < frame.clicks.count, let state = ClickEffects.state(effect.type, ageMs: frame.clicks[i].ageMs, knobs: knobs, videoWidth: videoWidth) {
                let p = frame.clicks[i].position
                points.append(CIVector(x: extent.minX + p.x * k, y: extent.maxY - p.y * k, z: 0, w: 1))
                states.append(CIVector(x: state.x, y: state.y, z: state.z, w: state.w))
            } else {
                points.append(CIVector(x: 0, y: 0, z: 0, w: 0))
                states.append(CIVector(x: 0, y: 0, z: 0, w: 0))
            }
        }
        guard points.contains(where: { $0.w > 0 }) else { return src }
        // Where the recording lands on the canvas: output pixels for the antialiasing and the noise.
        let video = videoRect(inBody: frame.screenRect)
        let outputPerPixel = max(video.width, 0.0001) / extent.width
        let maxReads: Double = quality == .export || quality == .pausedHigh ? 32 : 4
        let reach = ClickEffects.readReach01(effect.type) * videoWidth + 2
        let output = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
            arguments: [
                src.clampedToExtent(), points[0], points[1], points[2], states[0], states[1], states[2],
                CIVector(x: knobs.x, y: knobs.y, z: knobs.z, w: knobs.w),
                CIVector(x: effect.type == .ripple ? 1 : 2, y: videoWidth, z: 1.5 / outputPerPixel, w: maxReads),
                CIVector(
                    x: outputPerPixel, y: video.x - extent.minX * outputPerPixel,
                    z: -max(video.height, 0.0001) / extent.height, w: video.y + max(video.height, 0.0001) / extent.height * extent.maxY
                ),
            ]
        )
        return output?.cropped(to: extent) ?? src
    }

    static func ciColor(_ c: RGBA, alpha: Double? = nil) -> CIColor {
        CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(alpha ?? c.a))
    }
}
