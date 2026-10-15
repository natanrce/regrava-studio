import CoreImage
import CoreImage.CIFilterBuiltins
import RegravaCore
import Foundation

/// Builds one output frame: background, shadow, rounded screen, click ripple and cursor.
///
/// Inputs use top-left coordinates (like the rest of the project); Core Image uses
/// bottom-left, so every rectangle is flipped through `ciRect`.
public final class FrameCompositor: @unchecked Sendable {
    public let layout: CanvasLayout
    private let style: StyleConfig
    private let cursorConfig: CursorConfig
    private let pointPixelScale: Double
    private let cursor: CursorAsset?
    private let background: CIImage

    public init(project: Project, layout: CanvasLayout, cursor: CursorAsset?) {
        self.layout = layout
        style = project.style
        cursorConfig = project.cursor
        pointPixelScale = project.recording.pointPixelScale
        self.cursor = cursor
        background = Self.makeBackground(project.style.background, canvas: layout.canvas)
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
        let screen = ciRect(frame.screenRect)
        let zoomFactor = frame.screenRect.width / max(layout.restScreen.width, 1)

        // Screen image placed into its rectangle.
        let src = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let scaled = src
            .transformed(by: CGAffineTransform(scaleX: screen.width / max(src.extent.width, 1), y: screen.height / max(src.extent.height, 1)))
            .transformed(by: CGAffineTransform(translationX: screen.minX, y: screen.minY))

        let radius = style.cornerRadius * zoomFactor
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = screen
        mask.radius = Float(radius)
        mask.color = .white
        let blend = CIFilter.blendWithMask()
        blend.inputImage = scaled
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask.outputImage
        let roundedScreen = blend.outputImage ?? scaled

        var output = background

        if style.shadowOpacity > 0, style.shadowRadius > 0 {
            let shadowRadius = style.shadowRadius * zoomFactor
            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = screen.offsetBy(dx: 0, dy: -shadowRadius * 0.3)
            shape.radius = Float(radius)
            shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(style.shadowOpacity))
            if let shadow = shape.outputImage?.applyingGaussianBlur(sigma: shadowRadius / 2) {
                output = shadow.composited(over: output)
            }
        }

        output = roundedScreen.composited(over: output)

        let videoToCanvas = frame.screenRect.width / max(layout.videoSize.width, 1)
        let pixelsPerPoint = pointPixelScale * cursorConfig.sizeMultiplier * videoToCanvas

        if cursorConfig.showsClickRipple, let progress = frame.clickProgress, let position = frame.clickPosition {
            let center = ciPoint(layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect))
            output = Self.ripple(center: center, progress: progress, maxRadius: 22 * pixelsPerPoint).composited(over: output)
        }

        if cursorConfig.isVisible, let cursor, let position = frame.cursor {
            let tip = layout.canvasPoint(videoPoint: position, screenRect: frame.screenRect)
            let width = cursor.sizePoints.width * pixelsPerPoint
            let height = cursor.sizePoints.height * pixelsPerPoint
            let topLeft = Vec2(tip.x - cursor.hotspotPoints.x * pixelsPerPoint, tip.y - cursor.hotspotPoints.y * pixelsPerPoint)
            let target = ciRect(Rect2(x: topLeft.x, y: topLeft.y, width: width, height: height))
            let image = cursor.image
            let placed = image
                .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            output = placed.composited(over: output)
        }

        return output.cropped(to: canvasRect)
    }

    static func ripple(center: CGPoint, progress: Double, maxRadius: Double) -> CIImage {
        let eased = 1 - pow(1 - progress, 3)
        let radius = max(maxRadius * (0.35 + 0.65 * eased), 1)
        let alpha = 0.45 * (1 - progress)
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(radius * 0.55)
        gradient.radius1 = Float(radius)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(alpha))
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return (gradient.outputImage ?? CIImage.empty()).cropped(to: box)
    }

    static func makeBackground(_ style: BackgroundStyle, canvas: Rect2) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        switch style {
        case .solid(let color):
            return CIImage(color: ciColor(color)).cropped(to: rect)
        case let .linearGradient(from, to, angleDegrees):
            // Angle measured like ° = bottom→top, 90° = left→right.
            let radians = angleDegrees * .pi / 180
            let direction = CGPoint(x: sin(radians), y: cos(radians))
            let halfLength = (abs(direction.x) * rect.width + abs(direction.y) * rect.height) / 2
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            let gradient = CIFilter.linearGradient()
            // In Core Image y points up; CSS "up" is +y here as well.
            gradient.point0 = CGPoint(x: mid.x - direction.x * halfLength, y: mid.y - direction.y * halfLength)
            gradient.point1 = CGPoint(x: mid.x + direction.x * halfLength, y: mid.y + direction.y * halfLength)
            gradient.color0 = ciColor(from)
            gradient.color1 = ciColor(to)
            return (gradient.outputImage ?? CIImage(color: ciColor(from))).cropped(to: rect)
        }
    }

    static func ciColor(_ c: RGBA) -> CIColor {
        CIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
}
