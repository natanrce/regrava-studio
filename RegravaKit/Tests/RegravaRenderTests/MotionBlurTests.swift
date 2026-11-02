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

    /// 8×8 Bayer threshold v / 64 of a top-left output pixel.
    private func bayer(_ x: Int, _ y: Int) -> Double {
        let x0 = x & 1, y0 = y & 1, x1 = (x >> 1) & 1, y1 = (y >> 1) & 1, x2 = (x >> 2) & 1, y2 = (y >> 2) & 1
        let v = ((x0 ^ y0) * 2 + y0) * 16 + ((x1 ^ y1) * 2 + y1) * 4 + (x2 ^ y2) * 2 + y2
        return Double(v) / 64
    }

    /// Reads at (k + phase) / n of the way, the phase from Bayer noise at the output pixel,
    /// each the block at `now` moved back into that read's rect (read bilinearly).
    @Test func trailReadsAreDitheredPerPixel() throws {
        let now = CGRect(x: 100, y: 0, width: 20, height: 16)
        let layer = CIImage(color: .white).cropped(to: now)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 16)
        let blurred = try #require(MotionBlur.trail(layer, now: now, start: CGRect(x: 60, y: 0, width: 20, height: 16), samples: 4, bounds: bounds, canvasHeight: 16))
        for y in 0..<8 {
            for x in 72..<80 {
                let phase = bayer(x, 15 - y)
                let expected = (0..<4).map { k -> Double in
                    let t = (Double(k) + phase) / 4
                    let q = 100 + (Double(x) + 0.5 - (60 + 40 * t))
                    return min(max(q - 99.5, 0), 1) * min(max(120.5 - q, 0), 1)
                }.reduce(0, +) / 4
                #expect(abs(alpha(of: blurred, at: CGPoint(x: x, y: y)) - expected) < 2e-3, "\(x), \(y)")
            }
        }
        // At rest the layer comes back unchanged.
        let still = try #require(MotionBlur.trail(layer, now: now, start: now, samples: 4, bounds: bounds, canvasHeight: 16))
        #expect(abs(alpha(of: still, at: CGPoint(x: 110, y: 4)) - 1) < 1e-3)
        #expect(alpha(of: still, at: CGPoint(x: 90, y: 4)) < 1e-3)
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
