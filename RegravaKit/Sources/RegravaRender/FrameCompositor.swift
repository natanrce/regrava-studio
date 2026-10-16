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

    /// `assetsDirectory` is the project folder (for background images).
    public init(project: Project, layout: CanvasLayout, cursors: CursorLibrary?, assetsDirectory: URL? = nil) {
        self.layout = layout
        style = project.style
        cursorConfig = project.cursor
        pointPixelScale = project.recording.pointPixelScale
        self.cursors = cursors
        motionBlurAmount = project.animation.motionBlurAmount
        fps = project.recording.fps
        background = Self.makeBackground(project.style.background, canvas: layout.canvas, assetsDirectory: assetsDirectory)
    }

    private var canvasHeight: Double { layout.canvas.height }

    private func ciRect(_ r: Rect2) -> CGRect {
        CGRect(x: r.x, y: canvasHeight - r.y - r.height, width: r.width, height: r.height)
    }

    private func ciPoint(_ p: Vec2) -> CGPoint {
        CGPoint(x: p.x, y: canvasHeight - p.y)
    }

    public func compose(source: CIImage, frame: CameraFrame) -> CIImage {
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
            let middle = isStatic ? now : trailStart.lerp(to: now, 0.5)
            let screen = ciRect(middle)
            let zoomFactor = middle.width / max(layout.restScreen.width, 1)
            let radius = min(style.cornerRadius * zoomFactor, min(screen.width, screen.height) / 2)
            output = shadow(for: screen, radius: radius, zoomFactor: zoomFactor).composited(over: output)
        }
        var screenImage = screenLayer(src, rect: now)
        if !isStatic {
            let bounds = ciRect(now).union(ciRect(trailStart)).integral
            let samples = MotionBlur.sampleCount(travel: now.cornerTravel(to: trailStart))
            if let blurred = MotionBlur.accumulate(samples: samples, bounds: bounds, layer: { t in
                self.screenLayer(src, rect: trailStart.lerp(to: now, t))
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
                if let blurred = MotionBlur.accumulate(samples: MotionBlur.sampleCount(travel: travel), bounds: bounds, layer: { t in
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

        return output.cropped(to: canvasRect)
    }

    /// The recording placed into `rect` with rounded corners and the inset border.
    private func screenLayer(_ src: CIImage, rect: Rect2) -> CIImage {
        let screen = ciRect(rect)
        let zoomFactor = rect.width / max(layout.restScreen.width, 1)
        let radius = min(style.cornerRadius * zoomFactor, min(screen.width, screen.height) / 2)
        let scaled = src
            .transformed(by: CGAffineTransform(scaleX: screen.width / max(src.extent.width, 1), y: screen.height / max(src.extent.height, 1)))
            .transformed(by: CGAffineTransform(translationX: screen.minX, y: screen.minY))
        var image = masked(scaled, to: screen, radius: radius)

        // Inset: a colored border inside the screen edge.
        if style.inset.isOn {
            let width = style.inset.size * zoomFactor
            let ring = CIFilter.blendWithMask()
            ring.inputImage = roundedRect(screen, radius: radius, color: Self.ciColor(style.inset.color, alpha: style.inset.alpha))
            ring.backgroundImage = CIImage.empty()
            ring.maskImage = roundedRect(screen, radius: radius, color: .white)
                .applyingFilter("CISourceOutCompositing", parameters: [
                    kCIInputBackgroundImageKey: roundedRect(screen.insetBy(dx: width, dy: width), radius: max(radius - width, 0), color: .white),
                ])
            if let ringImage = ring.outputImage { image = ringImage.composited(over: image) }
        }
        return image
    }

    // MARK: Pieces

    private func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(max(radius, 0))
        generator.color = color
        return generator.outputImage ?? CIImage.empty()
    }

    private func masked(_ image: CIImage, to rect: CGRect, radius: Double) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = roundedRect(rect, radius: radius, color: .white)
        return blend.outputImage ?? image
    }

    /// Classic: centered soft shadow. Directional: offset by `distance` along `angle`
    /// (0° = straight down, growing clockwise), blurred by `blur`.
    private func shadow(for screen: CGRect, radius: Double, zoomFactor: Double) -> CIImage {
        let s = style.shadow
        let scale = layout.canvas.height / 1080 * zoomFactor
        var offset = CGSize.zero
        if s.isDirectional {
            let angle = (s.angle - 90) * .pi / 180
            offset = CGSize(width: cos(angle) * s.distance * scale, height: sin(angle) * s.distance * scale)
        }
        let blur = (s.isDirectional ? s.blur : 30) * scale
        let opacity = min(s.intensity / 0.6, 1) * 0.85
        let shape = roundedRect(screen.offsetBy(dx: offset.width, dy: offset.height), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(opacity)))
        return shape.applyingGaussianBlur(sigma: max(blur, 0.1))
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
                // Aspect-fill, then blur (clamped so edges stay opaque).
                let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
                var filled = image
                    .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                filled = filled.transformed(by: CGAffineTransform(
                    translationX: (rect.width - filled.extent.width) / 2,
                    y: (rect.height - filled.extent.height) / 2
                ))
                if config.blur > 0 {
                    filled = filled.clampedToExtent().applyingGaussianBlur(sigma: config.blur / 2)
                }
                return filled.cropped(to: rect)
            }
            return gradient(config, rect: rect)
        case .gradient, .wallpaper, .unsplash:
            // Wallpapers and Unsplash photos are not bundled; they fall back to the gradient.
            return gradient(config, rect: rect)
        }
    }

    /// Two-stop gradient from the top-left corner (0,0) to the bottom-right corner (1,1).
    static func gradient(_ config: BackgroundConfig, rect: CGRect) -> CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: rect.minX, y: rect.maxY)
        filter.point1 = CGPoint(x: rect.maxX, y: rect.minY)
        filter.color0 = ciColor(config.gradientFrom)
        filter.color1 = ciColor(config.gradientTo)
        return (filter.outputImage ?? CIImage(color: ciColor(config.gradientFrom))).cropped(to: rect)
    }

    static func ciColor(_ c: RGBA, alpha: Double? = nil) -> CIColor {
        CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(alpha ?? c.a))
    }
}
