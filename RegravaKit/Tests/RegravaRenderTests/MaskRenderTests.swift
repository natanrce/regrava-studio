import CoreImage
import Testing
@testable import RegravaCore
@testable import RegravaRender

@Suite struct MaskRenderTests {
    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return p
    }

    /// Left half red, right half blue.
    private var source: CIImage {
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        return blue.composited(over: red)
    }

    private func frame(_ type: MaskType, active: Bool) -> MaskFrame {
        MaskFrame(bounds01: Rect2(x: 0.25, y: 0.25, width: 0.5, height: 0.5), borderRadius01: 0, type: type, highlightOpacity: 0.5, active: active, opacity: 1)
    }

    @Test func sensitiveDataBecomesAColourField() {
        let out = MaskRenderer.apply(frame(.sensitiveData, active: true), to: source)
        // Left edge of the area keeps the left quadrants' colour, the middle blends both.
        let left = pixel(out, 51, 50), middle = pixel(out, 100, 50)
        #expect(left[0] > 0.9 && left[2] < 0.1)
        #expect(middle[0] > 0.2 && middle[2] > 0.2)
        // Outside the mask nothing changes.
        #expect(pixel(out, 10, 10)[0] > 0.99)
    }

    @Test func highlightDarkensOutside() {
        let out = MaskRenderer.apply(frame(.highlight, active: false), to: source)
        #expect(pixel(out, 60, 50)[0] > 0.99)      // inside untouched
        // Outside, the squared encoded value is halved: encoded √½, linear 0.4587.
        #expect(abs(pixel(out, 10, 10)[0] - 0.4587) < 0.003)
    }

    /// A quadrant's average is the mean of encoded values: half black, half white reads as
    /// encoded 0.5 (linear 0.214), not linear 0.5.
    @Test func coverColoursAverageEncodedValues() {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var stripes = black
        for x in stride(from: 0, to: 200, by: 2) {
            stripes = CIImage(color: .white).cropped(to: CGRect(x: x, y: 0, width: 1, height: 100)).composited(over: stripes)
        }
        let out = MaskRenderer.apply(MaskFrame(bounds01: Rect2(x: 0.25, y: 0.25, width: 0.5, height: 0.5), borderRadius01: 0, type: .sensitiveData, highlightOpacity: 0, active: true, opacity: 1), to: stripes)
        #expect(abs(pixel(out, 100, 50)[0] - 0.214) < 0.02)
    }

    /// The reads per quadrant: inset by the mip footprint, at the first level needing at most
    /// 256 reads (or the deepest allowed one).
    @Test func latticeOfAMask() throws {
        #expect(MaskRenderer.mipFootprint(level: 0) == 0.5)
        #expect(MaskRenderer.mipFootprint(level: 1) == 1)
        #expect(MaskRenderer.mipFootprint(level: 2) == 4)
        #expect(MaskRenderer.mipFootprint(level: 3) == 10)
        let lattice = try #require(MaskRenderer.lattice(bounds: Rect2(x: 50, y: 25, width: 100, height: 50), contentSize: CGSize(width: 200, height: 100), mipLevelCount: 8))
        #expect(lattice == MaskRenderer.Lattice(rect: Rect2(x: 58, y: 33, width: 84, height: 34), tapsX: 11, tapsY: 5, level: 2))
        #expect(MaskRenderer.limitTaps(40, 10) == (25, 10))
        #expect(MaskRenderer.limitTaps(3, 300) == (3, 85))
        #expect(MaskRenderer.lattice(bounds: Rect2(x: 300, y: 0, width: 10, height: 10), contentSize: CGSize(width: 200, height: 100), mipLevelCount: 8) == nil)
    }

    /// Corners follow the smooth-corner curve (smoothing 1) of the screen's own clip.
    @Test func cornersAreSmooth() {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let mask = MaskFrame(bounds01: Rect2(x: 0.25, y: 0.25, width: 0.5, height: 0.5), borderRadius01: 0.1, type: .highlight, highlightOpacity: 1, active: false, opacity: 1)
        let out = MaskRenderer.apply(mask, to: white)
        let shape = SmoothShapes.coverage(CGRect(x: 100, y: 100, width: 200, height: 200), radius: 40, smoothing: 1)
        let circular = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: CGRect(x: 100, y: 100, width: 200, height: 200)), "inputRadius": 40, "inputColor": CIColor.white])!.outputImage!
        for i in 0..<30 {
            let x = 100 + Double(i), y = 300 - Double(i) - 1
            // White dimmed to black outside, mixed squared: encoded √coverage.
            let encoded = Double(pixel(shape, x, y)[3]).squareRoot()
            let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            #expect(abs(Double(pixel(out, x, y)[0]) - linear) < 0.01)
        }
        // Along the edge, the smooth curve departs from the straight side earlier than a circle.
        #expect(pixel(shape, 100.5, 300 - 41)[3] < pixel(circular, 100.5, 300 - 41)[3] - 0.1)
        #expect(pixel(out, 200, 200)[0] > 0.99)
    }
}
