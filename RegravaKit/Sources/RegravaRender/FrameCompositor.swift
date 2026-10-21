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
    private let background: CIImage
    private let motionBlurAmount: Double
    private let fps: Int
    private let camera: CameraConfig
    /// A cutout layout is used somewhere, so camera frames are matted (`isCameraMatted`).
    private let isCameraMatted: Bool
    /// Burned-in captions, drawn above everything.
    private let captions: CaptionRenderer?
    /// Keyboard shortcuts, the top-most layer.
    private let shortcuts: ShortcutRenderer?
    /// The colour grade already mixed with the identity by `lutIntensity`.
    private let cameraGrade: (data: Data, size: Int)?

    /// `assetsDirectory` is the project folder (for background images).
    public init(project: Project, layout: CanvasLayout, cursors: CursorLibrary?, assetsDirectory: URL? = nil, transcript: [TranscriptWord] = []) {
        self.layout = layout
        style = project.style
        cursorConfig = project.cursor
        pointPixelScale = project.recording.pointPixelScale
        self.cursors = cursors
        motionBlurAmount = project.animation.motionBlurAmount
        fps = project.recording.fps
        camera = project.camera
        isCameraMatted = project.isCutoutLayoutUsed
        captions = CaptionRenderer(project: project, words: transcript, canvas: layout.canvas)
        shortcuts = ShortcutRenderer(project: project, canvas: layout.canvas, captionsShown: captions != nil)
        cameraGrade = Self.loadGrade(project.camera, assetsDirectory: assetsDirectory)
        background = Self.makeBackground(project.style.background, canvas: layout.canvas, assetsDirectory: assetsDirectory)
    }

    private var canvasHeight: Double { layout.canvas.height }

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
        // Masks act on the recording itself, so they follow zoom and motion blur.
        let src = MaskRenderer.apply(frame.mask, to: source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)))
        let strength = MotionBlur.strength(amount: motionBlurAmount, fps: fps, disabled: frame.isInstantSnap)

        // Screen trail: from lerp(now, before, strength) to now (`rf.trailStart`).
        let now = frame.screenRect
        let trailStart = strength > 0 ? now.lerp(to: frame.previousScreenRect ?? now, strength) : now
        let isStatic = strength == 0 || now.isClose(to: trailStart, tolerance: 1)

        var output = background
        if style.shadow.intensity > 0 {
            // One shadow at the trail's middle, under the inset and the content.
            let middle = isStatic ? now : trailStart.lerp(to: now, 0.5)
            let reference = frame.screenReferenceWidth > 0 ? frame.screenReferenceWidth : layout.restScreen.width
            output = partShadow(ciRect(middle), radius: screenRadius(middle, frame: frame), zoomFactor: middle.width / max(reference, 1)).composited(over: output)
        }
        var screenImage = screenLayer(src, rect: now, frame: frame)
        if !isStatic {
            let bounds = ciRect(now).union(ciRect(trailStart)).integral
            let samples = MotionBlur.sampleCount(travel: now.cornerTravel(to: trailStart), quality: quality)
            if let blurred = MotionBlur.accumulate(samples: samples, bounds: bounds, falloffRatio: MotionBlur.screenFalloffRatio, layer: { t in
                self.screenLayer(src, rect: trailStart.lerp(to: now, t), frame: frame)
            }) {
                screenImage = blurred
            }
        }
        output = screenImage.composited(over: output)

        let videoToCanvas = frame.screenRect.width / max(layout.videoSize.width, 1)
        let pixelsPerPoint = pointPixelScale * cursorConfig.sizeMultiplier * videoToCanvas

        if let effect = cursorConfig.clickEffect, let progress = frame.clickProgress, let position = frame.clickPosition {
            let center = ciPoint(layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect))
            output = Self.clickEffect(effect, center: center, progress: progress, maxRadius: 22 * pixelsPerPoint).composited(over: output)
        }

        if !cursorConfig.hide, frame.cursorOpacity > 0, let cursors, let position = frame.cursor {
            let cursor = cursors.asset(named: frame.cursorName)
            let tip = layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect)
            var tipBefore = tip
            if let previous = frame.previousCursor {
                tipBefore = layout.canvasPoint(videoPoint: previous, screenRect: frame.previousScreenRect ?? frame.screenRect)
            }
            let cursorStrength = MotionBlur.strength(amount: motionBlurAmount, fps: fps, disabled: false)
            let trailTip = tip.lerp(to: tipBefore, cursorStrength)
            let scaleNow = frame.cursorScale
            let trailScale = scaleNow + (frame.previousCursorScale - scaleNow) * cursorStrength
            let travel = tip.distance(to: trailTip)
            var cursorImage = placedCursor(cursor, tip: tip, frame: frame, pixelsPerPoint: pixelsPerPoint * scaleNow)
            if cursorStrength > 0 && travel >= 1 {
                let bounds = cursorImage.extent
                    .union(placedCursor(cursor, tip: trailTip, frame: frame, pixelsPerPoint: pixelsPerPoint * trailScale).extent)
                    .integral
                if let blurred = MotionBlur.accumulate(samples: MotionBlur.sampleCount(travel: travel, quality: quality), bounds: bounds, layer: { t in
                    self.placedCursor(
                        cursor,
                        tip: trailTip.lerp(to: tip, t),
                        frame: frame,
                        pixelsPerPoint: pixelsPerPoint * (trailScale + (scaleNow - trailScale) * t)
                    )
                }) {
                    cursorImage = blurred
                }
            }
            output = cursorImage.composited(over: output)
        }

        // The webcam is drawn above everything.
        if let cameraImage, let rect = frame.cameraRect, frame.cameraOpacity > 0.001, rect.width > 0.5, rect.height > 0.5 {
            output = cameraLayer(cameraImage, rect: rect, frame: frame, quality: quality).composited(over: output)
        }
        if let captions { output = captions.draw(over: output, atPlayback: frame.timeMs) }
        if let shortcuts { output = shortcuts.draw(over: output, atPlayback: frame.timeMs) }

        return output.cropped(to: canvasRect)
    }

    /// Recording points to canvas pixels at `rect`'s width (`sourcePixelScale × k`).
    private func pointsToCanvas(_ rect: Rect2) -> Double {
        rect.width / max(layout.videoSize.width / max(pointPixelScale, 0.0001), 1)
    }

    /// `screenBorderRadius` in points, scaled with the drawn screen; 0 without padding or when
    /// the active layout disallows it.
    private func screenRadius(_ rect: Rect2, frame: CameraFrame) -> Double {
        guard frame.allowsScreenBorderRadius, style.paddingRatio > 0 else { return 0 }
        return style.cornerRadius * pointsToCanvas(rect)
    }

    /// The recording placed into `rect` with smooth corners, the inset band behind it.
    private func screenLayer(_ src: CIImage, rect: Rect2, frame: CameraFrame) -> CIImage {
        let screen = ciRect(rect)
        let radius = screenRadius(rect, frame: frame)
        let scaled = src
            .transformed(by: CGAffineTransform(scaleX: screen.width / max(src.extent.width, 1), y: screen.height / max(src.extent.height, 1)))
            .transformed(by: CGAffineTransform(translationX: screen.minX, y: screen.minY))
        var image = SmoothShapes.clip(scaled, to: screen, radius: radius)

        // Inset: a band outside the screen, behind it, only while the background shows.
        if style.inset.isOn, frame.isBackgroundVisible {
            let band = SmoothShapes.insetBand(screen, radius: radius, size: style.inset.size * pointsToCanvas(rect), origin01: style.inset.origin01, color: Self.ciColor(style.inset.color, alpha: style.inset.alpha))
            image = image.composited(over: band)
        }
        return image
    }

    /// The webcam covering `rect` (centred focal point), cropped, mirrored, with rounded corners,
    /// the screen's shadow, and faded and blurred while hiding.
    private func cameraLayer(_ image: CIImage, rect: Rect2, frame: CameraFrame, quality: RenderQuality) -> CIImage {
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
                var cast = partShadow(target, radius: radius, zoomFactor: frame.cameraSizeFactor)
                if c > 0.001 {
                    let silhouette = silhouetteShadow(of: layer, zoomFactor: frame.cameraSizeFactor)
                    cast = c >= 0.999 ? silhouette : Self.scaled(silhouette, c).composited(over: Self.scaled(cast, 1 - c))
                }
                layer = layer.composited(over: cast)
            }
            return layer
        }
        var layer = placedLayer(rect)
        // The trail from lerp(now, before, strength) to now; instant zoom snaps don't turn it off.
        let strength = MotionBlur.strength(amount: motionBlurAmount, fps: fps, disabled: false)
        if strength > 0, let before = frame.previousCameraRect {
            let trailStart = rect.lerp(to: before, strength)
            if !rect.isClose(to: trailStart, tolerance: 1) {
                let reach = style.shadow.intensity > 0 ? (style.shadow.blur * 8 * frame.cameraSizeFactor + style.shadow.distance * 6 + 16) * layout.scale + 8 : 8
                let bounds = now.union(ciRect(trailStart)).insetBy(dx: -reach, dy: -reach).integral
                let samples = MotionBlur.sampleCount(travel: rect.cornerTravel(to: trailStart), quality: quality)
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
        return layer
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

    /// The screen's or the camera's shadow: black at the intensity, blur `blur × 8 × k`;
    /// Directional marches toward a light fixed on the stage.
    private func partShadow(_ rect: CGRect, radius: Double, zoomFactor k: Double) -> CIImage {
        let s = style.shadow
        let unit = layout.scale
        let blur = s.blur * 8 * k * unit
        let offset = shadowOffset
        var directional: (light: CGPoint, radius: Double, falloff: Double)?
        if s.isDirectional {
            // Stage centre − polar(angle, 1.5 × |stage / 2|), y down.
            let canvas = layout.canvas
            let a = s.angle * .pi / 180
            let reach = 1.5 * hypot(canvas.width / 2, canvas.height / 2)
            let light = CGPoint(x: canvas.width / 2 - cos(a) * reach, y: canvas.height - (canvas.height / 2 - sin(a) * reach))
            directional = (light, max(blur * 2.5, 4 * unit), max(hypot(offset.dx, offset.dy) * 6, 40 * unit))
        }
        return SmoothShapes.shadow(rect, radius: radius, .init(alpha: s.intensity, blur: blur, offset: offset, directional: directional, unit: unit))
    }

    /// The shadow cast by the camera's own alpha (`getContentShadowMask`), with the same alpha
    /// and offset; its blur kernel is not known, a Gaussian stands in.
    private func silhouetteShadow(of layer: CIImage, zoomFactor: Double) -> CIImage {
        let s = style.shadow
        let offset = shadowOffset
        let blur = s.blur * 8 * zoomFactor * layout.scale
        let shape = layer.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.intensity)),
        ]).transformed(by: CGAffineTransform(translationX: offset.dx, y: offset.dy))
        return shape.applyingGaussianBlur(sigma: max(blur * 0.4, 0.1))
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
    private func placedCursor(_ cursor: CursorAsset, tip: Vec2, frame: CameraFrame, pixelsPerPoint: Double) -> CIImage {
        let width = cursor.sizePoints.width * pixelsPerPoint
        let height = cursor.sizePoints.height * pixelsPerPoint
        let topLeft = Vec2(tip.x - cursor.hotspotPoints.x * pixelsPerPoint, tip.y - cursor.hotspotPoints.y * pixelsPerPoint)
        let target = ciRect(Rect2(x: topLeft.x, y: topLeft.y, width: width, height: height))
        let image = cursor.image
        var placed = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        if cursorConfig.baseRotation != 0 {
            // Rotate around the hotspot; positive = clockwise.
            let pivot = ciPoint(tip)
            let rotation = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .rotated(by: -cursorConfig.baseRotation * .pi / 180)
                .translatedBy(x: -pivot.x, y: -pivot.y)
            placed = placed.transformed(by: rotation)
        }
        if frame.cursorOpacity < 1 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(frame.cursorOpacity)),
            ])
        }
        return placed
    }

    /// Circle: a filled disc that grows and fades. Ripple: an expanding ring.
    static func clickEffect(_ effect: ClickEffect, center: CGPoint, progress: Double, maxRadius: Double) -> CIImage {
        let eased = 1 - pow(1 - progress, 3)
        let radius = max(maxRadius * (0.35 + 0.65 * eased), 1)
        let alpha = 0.45 * (1 - progress)
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(alpha))
        let clear = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        switch effect {
        case .circle:
            gradient.radius0 = Float(radius * 0.85)
            gradient.radius1 = Float(radius)
            gradient.color0 = white
            gradient.color1 = clear
        case .ripple:
            // Bright edge fading inward; the outside is cropped by the circle mask below.
            gradient.radius0 = Float(radius * 0.55)
            gradient.radius1 = Float(radius)
            gradient.color0 = clear
            gradient.color1 = white
        }
        var image = gradient.outputImage ?? CIImage.empty()
        if effect == .ripple {
            let disc = CIFilter.radialGradient()
            disc.center = center
            disc.radius0 = Float(radius)
            disc.radius1 = Float(radius + 1)
            disc.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            disc.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = image
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = disc.outputImage
            image = blend.outputImage ?? image
        }
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return image.cropped(to: box)
    }

    static func makeBackground(_ config: BackgroundConfig, canvas: Rect2, assetsDirectory: URL?) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        switch config.kind {
        case .color:
            return CIImage(color: ciColor(config.color)).cropped(to: rect)
        case .image:
            if let name = config.imageFileName, let directory = assetsDirectory,
               let image = CIImage(contentsOf: directory.appendingPathComponent(name)) {
                return filled(image, rect: rect, blur: config.blur)
            }
            return gradient(config, rect: rect)
        case .wallpaper:
            if let url = WallpaperLibrary.url(for: config.systemName), let image = CIImage(contentsOf: url) {
                return filled(image, rect: rect, blur: config.blur)
            }
            return gradient(config, rect: rect)
        case .gradient, .unsplash:
            // Unsplash photos are not available; they fall back to the gradient.
            return gradient(config, rect: rect)
        }
    }

    /// Aspect-fill, then blur (clamped so edges stay opaque).
    static func filled(_ image: CIImage, rect: CGRect, blur: Double) -> CIImage {
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        var filled = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        filled = filled.transformed(by: CGAffineTransform(
            translationX: (rect.width - filled.extent.width) / 2,
            y: (rect.height - filled.extent.height) / 2
        ))
        if blur > 0 {
            filled = filled.clampedToExtent().applyingGaussianBlur(sigma: blur / 2)
        }
        return filled.cropped(to: rect)
    }

    /// Gradient from the top-left corner (0,0) to the bottom-right corner (1,1), stops evenly
    /// spaced; drawn once per canvas size.
    static func gradient(_ config: BackgroundConfig, rect: CGRect) -> CIImage {
        let stops = config.gradientStops.count >= 2 ? config.gradientStops : [config.gradientFrom, config.gradientTo]
        let width = max(Int(rect.width), 1), height = max(Int(rect.height), 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgGradient = CGGradient(
                colorsSpace: space,
                colors: stops.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) } as CFArray,
                locations: stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
              ) else {
            return CIImage(color: ciColor(config.gradientFrom)).cropped(to: rect)
        }
        // Core Graphics is bottom-left: top-left is (0, height).
        context.drawLinearGradient(cgGradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let image = context.makeImage() else { return CIImage(color: ciColor(config.gradientFrom)).cropped(to: rect) }
        return CIImage(cgImage: image).cropped(to: rect)
    }

    static func ciColor(_ c: RGBA, alpha: Double? = nil) -> CIColor {
        CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(alpha ?? c.a))
    }
}
