import CoreImage
import Testing
@testable import RegravaCore
@testable import RegravaRender

@Suite struct DebandTests {
    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return p
    }

    /// A one-step band is smoothed; a hard edge far above the threshold is kept.
    @Test func smoothsBandsAndKeepsEdges() {
        let size = CGRect(x: 0, y: 0, width: 64, height: 64)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ v: CGFloat) -> CIImage { CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: space)!) }
        let banded = color(101.0 / 255).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64)).composited(over: color(100.0 / 255).cropped(to: size))
        let out = Deband.apply(banded, settings: .wallpaper)
        #expect(out.extent == size)
        // Next to the step, values land between the two levels (plus the dither).
        let near = (0..<8).map { pixel(out, 31, CGFloat(8 + $0))[0] * 255 }
        #expect(near.contains { $0 > 100.2 && $0 < 100.8 })
        let edge = color(0.2).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64)).composited(over: color(0.8).cropped(to: size))
        let kept = Deband.apply(edge, settings: .wallpaper)
        #expect(abs(pixel(kept, 31, 20)[0] - 0.8) < 0.01)
        #expect(abs(pixel(kept, 32, 20)[0] - 0.2) < 0.01)
    }
}
