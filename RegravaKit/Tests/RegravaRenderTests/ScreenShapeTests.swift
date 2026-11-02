import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct ScreenShapeTests {
    private func render(_ edit: (inout Project) -> Void, name: String) throws -> (CIImage, CanvasLayout, CameraFrame) {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 2000, fps: 30), mouseEvents: [], style: StyleConfig(aspectRatio: 16.0 / 9, paddingRatio: 0.1))
        project.style.background.kind = .color; project.style.background.color = RGBA(1, 1, 1)
        edit(&project)
        let layout = CanvasLayout(project: project)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let frame = CameraTrack(project: project).frame(at: 500)
        let image = FrameCompositor(project: project, layout: layout, cursors: nil).compose(source: source, frame: frame)
        if let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] {
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return (image, layout, frame)
    }

    private func pixel(_ image: CIImage, _ x: Double, _ yTop: Double, height: Double) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: height - yTop - 1, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return p
    }

    @Test func screenCornersScaleWithTheScreenInPoints() throws {
        let (image, layout, frame) = try render({ $0.style.shadow.intensity = 0; $0.style.cornerRadius = 64 }, name: "screen-corners")
        let r = frame.screenRect
        let h = layout.canvas.height
        // 64 pt over a 1920 pt recording drawn r.width wide: the corner pixel is background.
        #expect(pixel(image, r.x + 1, r.y + 1, height: h)[0] > 240)
        // Along the edge, 2r from the corner (where the smooth curve starts), it is the screen.
        let radius = 64 * r.width / 1920
        #expect(pixel(image, r.x + 2.2 * radius, r.y + 1, height: h)[2] > 150)
    }

    @Test func classicShadowFollowsTheAngle() throws {
        let (image, layout, frame) = try render({ $0.style.shadow = ShadowConfig(intensity: 0.6, isDirectional: false, distance: 40, angle: 90, blur: 10) }, name: "screen-shadow-classic")
        let r = frame.screenRect
        let h = layout.canvas.height
        let below = pixel(image, r.midX, r.endY + 20 * layout.scale, height: h)
        let above = pixel(image, r.midX, r.y - 20 * layout.scale, height: h)
        // 90° points down: darker under the screen than over it.
        #expect(below[0] < above[0], "\(below) \(above)")
    }

    @Test func directionalShadowAndInsetRender() throws {
        let (image, layout, frame) = try render({
            $0.style.shadow = ShadowConfig()
            $0.style.inset = InsetConfig(size: 8, color: RGBA(1, 0, 0), alpha: 1, origin01: Vec2(0.5, 0.5))
        }, name: "screen-shadow-directional")
        let r = frame.screenRect
        // The inset band sits just outside the screen edge, in red.
        let band = pixel(image, r.midX, r.y - 4 * r.width / 1920, height: layout.canvas.height)
        #expect(band[0] > 200 && band[1] < 80, "\(band)")
    }
}

@Suite struct ContentShadowTests {
    private func alpha(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> Float {
        var p = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return p[3]
    }

    /// A cut-out person casts the shadow of their own alpha, not of the frame: a disc inside a
    /// 200 px square shades under the disc and leaves the square's empty corners clear.
    @Test func classicSilhouetteFollowsTheAlpha() {
        let square = CGRect(x: 100, y: 100, width: 200, height: 200)
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 200, y: 200), "inputRadius0": 60, "inputRadius1": 61,
            "inputColor0": CIColor.white, "inputColor1": CIColor.clear,
        ])!.outputImage!.cropped(to: square)
        let shadow = SmoothShapes.Shadow(alpha: 0.5, blur: 4, offset: CGVector(dx: 10, dy: -10), directional: nil, unit: 1)
        let out = SmoothShapes.contentShadow(disc, caster: square, radius: 0, shadow)
        // Under the disc's centre, moved by the offset: full alpha × smoothstep(0, 0.75, 1).
        #expect(abs(alpha(out, 210, 190) - 0.5) < 0.01)
        // A corner of the square, empty in the content, casts nothing.
        #expect(alpha(out, 120, 120) < 0.01)
        // Directional: still nothing from the empty corner, something next to the disc.
        let directional = SmoothShapes.Shadow(alpha: 0.5, blur: 4, offset: CGVector(dx: 10, dy: -10), directional: (CGPoint(x: -1000, y: 1200), 10, 60), unit: 1)
        let cast = SmoothShapes.contentShadow(disc, caster: square, radius: 0, directional)
        #expect(alpha(cast, 120, 120) < 0.05)
        #expect(alpha(cast, 270, 160) > 0.05)
    }
}
