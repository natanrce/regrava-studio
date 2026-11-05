import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Frames drawn at the output size against frames composed at canvas size and scaled.
struct OutputSizeRenderTests {
    private func project() -> Project {
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1280, height: 800), pointPixelScale: 2, durationMs: 3000, fps: 60),
            mouseEvents: [
                MouseEvent(kind: .move, timeMs: 0, position: Vec2(100, 100)),
                MouseEvent(kind: .move, timeMs: 900, position: Vec2(1000, 600)),
                MouseEvent(kind: .down, timeMs: 1000, position: Vec2(1000, 600)),
                MouseEvent(kind: .up, timeMs: 1050, position: Vec2(1000, 600)),
            ],
            style: StyleConfig(aspectRatio: 16.0 / 9)
        )
        project.zooms = [ZoomRange(startMs: 200, endMs: 2500, scale: 2)]
        return project
    }

    /// Stripes and a gradient, so scaling and edges show.
    private func source() -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0.9, green: 0.9, blue: 0.95), "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.4), "inputWidth": 24,
        ])!.outputImage!.cropped(to: extent)
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 1280, y: 800),
            "inputColor0": CIColor(red: 1, green: 0, blue: 0, alpha: 0.5), "inputColor1": CIColor(red: 0, green: 0, blue: 1, alpha: 0.5),
        ])!.outputImage!.cropped(to: extent)
        return ramp.composited(over: stripes)
    }

    private func pixels(_ image: CIImage, _ size: CGSize) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: Int(size.width) * Int(size.height) * 4)
        CIContext().render(image, toBitmap: &data, rowBytes: Int(size.width) * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return data
    }

    @Test func scalesOnlyCanvasPixels() {
        var frame = CameraFrame(timeMs: 10, screenRect: Rect2(x: 10, y: 20, width: 300, height: 200))
        frame.cursor = Vec2(50, 60)
        frame.previousScreenRect = Rect2(x: 0, y: 0, width: 100, height: 50)
        frame.cameraRect = Rect2(x: 1, y: 2, width: 3, height: 4)
        frame.cameraCornerRadius = 12
        frame.screenReferenceWidth = 400
        frame.backgroundRect = Rect2(x: -5, y: -5, width: 1930, height: 1090)
        frame.backgroundBlurRadius = 7
        frame.cursorFadeBlurRadius = 3
        let half = frame.scaled(by: 0.5)
        #expect(half.screenRect == Rect2(x: 5, y: 10, width: 150, height: 100))
        #expect(half.previousScreenRect == Rect2(x: 0, y: 0, width: 50, height: 25))
        #expect(half.cameraRect == Rect2(x: 0.5, y: 1, width: 1.5, height: 2))
        #expect(half.cameraCornerRadius == 6)
        #expect(half.screenReferenceWidth == 200)
        #expect(half.backgroundRect == Rect2(x: -2.5, y: -2.5, width: 965, height: 545))
        // Video pixels and stage units are unchanged.
        #expect(half.cursor == Vec2(50, 60))
        #expect(half.backgroundBlurRadius == 7)
        #expect(half.cursorFadeBlurRadius == 3)

        let layout = CanvasLayout(project: project())
        let small = layout.scaled(by: 0.5)
        #expect(small.canvas == Rect2(x: 0, y: 0, width: 960, height: 540))
        #expect(small.scale == layout.scale / 2)
        #expect(small.restScreen.width == layout.restScreen.width / 2)
        #expect(small.videoSize == layout.videoSize)
    }

    @Test func drawsAtTheOutputWidth() {
        let snapshot = RenderState.makeSnapshot(project: project(), cursors: nil, outputSize: Size2(width: 960, height: 540))
        #expect(snapshot.composesAtOutputSize)
        #expect(snapshot.compositor.outputScale == 0.5)
        #expect(snapshot.compositor.layout.canvas.width == 960)
        #expect(snapshot.outputScale(for: CGSize(width: 1280, height: 720)) == 1280.0 / 1920)
        // Another size gets its own compositor, kept for the next frame.
        let other = snapshot.compositor(scale: 2)
        #expect(other.outputScale == 2)
        #expect(snapshot.compositor(scale: 2) === other)
        let image = snapshot.render(source: source(), frame: snapshot.track.frame(at: 1000), quality: .export, size: CGSize(width: 960, height: 540))
        #expect(image.extent == CGRect(x: 0, y: 0, width: 960, height: 540))

        let canvasSized = RenderState.makeSnapshot(project: project(), cursors: nil)
        #expect(!canvasSized.composesAtOutputSize)
        #expect(canvasSized.outputScale(for: CGSize(width: 960, height: 540)) == 1)
    }

    /// The same frames either way, but for resampling: the old path scales finished 1920
    /// frames, the new one draws edges, blur and dither on output pixels.
    @Test(arguments: [CGSize(width: 960, height: 540), CGSize(width: 1280, height: 720), CGSize(width: 1281, height: 721)])
    func matchesTheScaledCanvas(size: CGSize) {
        let project = project()
        let scaled = RenderState.makeSnapshot(project: project, cursors: CursorLibrary.arrowOnly())
        let direct = RenderState.makeSnapshot(project: project, cursors: CursorLibrary.arrowOnly(), outputSize: Size2(width: size.width, height: size.height))
        let src = source()
        for t in [0.0, 600, 1000, 2000] {
            let frame = scaled.track.frame(at: t)
            let a = pixels(scaled.render(source: src, frame: frame, quality: .export, size: size), size)
            let b = pixels(direct.render(source: src, frame: frame, quality: .export, size: size), size)
            var sum = 0.0, far = 0
            for i in 0..<a.count {
                let d = abs(Int(a[i]) - Int(b[i]))
                sum += Double(d)
                if d > 32 { far += 1 }
            }
            let mean = sum / Double(a.count)
            // Stripes 24 px wide: resampled edges differ by a pixel at most.
            #expect(mean < 2.5, "t=\(t) \(size): mean \(mean)")
            #expect(Double(far) / Double(a.count) < 0.03, "t=\(t) \(size): \(far) far")
        }
    }
}
