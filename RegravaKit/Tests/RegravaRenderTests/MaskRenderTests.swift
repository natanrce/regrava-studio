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
        #expect(abs(pixel(out, 10, 10)[0] - 0.5) < 0.05)  // outside at 50%
    }
}
