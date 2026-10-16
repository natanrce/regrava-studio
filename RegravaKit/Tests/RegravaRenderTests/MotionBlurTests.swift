import CoreImage
import Testing
@testable import RegravaCore
@testable import RegravaRender

@Suite struct MotionBlurTests {
    private func alpha(of image: CIImage, at point: CGPoint) -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(pixel[3])
    }

    @Test func kernelsCompileAndAverageAlongTheTrail() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 10)
        // A 20 px wide block sweeping from x = 0 to x = 180.
        let blurred = MotionBlur.accumulate(samples: 16, bounds: bounds) { t in
            CIImage(color: .white).cropped(to: CGRect(x: 180 * t, y: 0, width: 20, height: 10))
        }
        #expect(blurred != nil)
        guard let blurred else { return }
        let middle = alpha(of: blurred, at: CGPoint(x: 100, y: 5))
        // Partially covered along the trail, never fully opaque nor empty.
        #expect(middle > 0.02 && middle < 0.5)
    }

    @Test func staticFramesAreNotBlurred() {
        #expect(MotionBlur.strength(amount: 1, fps: 60, disabled: true) == 0)
        #expect(MotionBlur.strength(amount: 0.5, fps: 30, disabled: false) == 0.25)
        #expect(MotionBlur.sampleCount(travel: 2) == 1)
        #expect(MotionBlur.sampleCount(travel: 1000) == 16)
    }

    @Test func zoomTransitionFrameIsBlurred() {
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 640, height: 360), pointPixelScale: 1, durationMs: 3000, fps: 60),
            mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(600, 300))],
            style: StyleConfig(aspectRatio: 16.0 / 9)
        )
        project.zooms = [ZoomRange(startMs: 500, endMs: 2500, scale: 2)]
        let snapshot = RenderState.makeSnapshot(project: project, cursors: nil)
        let frame = snapshot.track.frame(at: 700)
        #expect(frame.previousScreenRect != nil)
        #expect(frame.screenRect.cornerTravel(to: frame.previousScreenRect!) > 1)
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = snapshot.compositor.compose(source: source, frame: frame)
        #expect(image.extent.width > 0)
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        #expect(!pixel.contains { $0.isNaN })
    }
}
