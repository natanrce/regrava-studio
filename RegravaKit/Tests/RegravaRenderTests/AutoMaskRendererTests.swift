import CoreImage
import Foundation
import Testing
import RegravaCore
@testable import RegravaRender

struct AutoMaskRendererTests {
    /// A white page with black text: the cover takes the page colour around it, hiding the text.
    @Test func coversTextWithTheSurroundingColour() throws {
        let size = CGSize(width: 400, height: 200)
        let page = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(origin: .zero, size: size))
        // "Text": a dark bar at top-left pixels (100, 40, 120, 16).
        let bar = CIImage(color: .black).cropped(to: CGRect(x: 100, y: 200 - 40 - 16, width: 120, height: 16))
        let image = bar.composited(over: page)
        let video = Size2(width: 400, height: 200)
        let frame = AutoMaskFrame(bounds01: [Rect2(x: 92 / 400, y: 32 / 200, width: 136 / 400, height: 32 / 200)],
                                  faceBounds01: [Rect2(x: 300 / 400, y: 120 / 200, width: 40 / 400, height: 40 / 200)])
        let out = AutoMaskRenderer.apply(frame, to: image, crop01: ScreenCropConfig.full, videoSize: video)
        let context = CIContext()
        var pixel = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 160, y: 200 - 48, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        print("COVER pixel \(pixel)")
        #expect(pixel[0] > 0.6) // the black text is gone
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 160, y: 200 - 48, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        #expect(pixel[0] < 0.1)
    }
}
