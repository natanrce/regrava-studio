import CoreImage
import Testing
@testable import RegravaCore
@testable import RegravaRender

@Suite struct BackdropRenderTests {
    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return p
    }

    /// OKLCH of sRGB red: L 0.62796, C 0.25768, h 29.23°.
    @Test func stopsAreConvertedToOklch() {
        let red = Backdrop.Oklch(srgb: RGBA(1, 0, 0))
        #expect(abs(red.l - 0.627955) < 1e-4)
        #expect(abs(red.c - 0.257683) < 1e-4)
        #expect(abs(red.h * 180 / .pi - 29.2339) < 1e-2)
        // Hues move by the short way round; grey keeps the running hue.
        #expect(abs(Backdrop.GradientUniforms.wrap(1.9 * .pi) - (-0.1 * .pi)) < 1e-9)
        let uniforms = Backdrop.GradientUniforms(BackgroundGradient(colors: [RGBA(1, 0, 0), RGBA(0.5, 0.5, 0.5), RGBA(0, 0, 1)]))
        #expect(uniforms.count == 3)
        #expect(uniforms.offsets == [0, 0.5, 1, 1, 1, 1, 1, 1])
        #expect(abs(uniforms.colors[1].z - uniforms.colors[0].z) < 1e-9)
        #expect(uniforms.colors[7] == uniforms.colors[2])
    }

    /// Black to white meets at OKLCH lightness 0.5 halfway: linear 0.125, not the 0.214 of a
    /// mix of encoded values.
    @Test func gradientsMixInOklchAlongTheirLine() {
        let gradient = BackgroundGradient(start: Vec2(0, 0), end: Vec2(1, 0), stops: [.init(color: RGBA(0, 0, 0), at: 0), .init(color: RGBA(1, 1, 1), at: 1)])
        let image = Backdrop.gradient(gradient, stage: Size2(width: 1920, height: 1080))
        // At most 1024 px on the long side.
        #expect(image.extent == CGRect(x: 0, y: 0, width: 1024, height: 576))
        let middle = pixel(image, 511.5, 300)
        #expect(abs(middle[0] - 0.125) < 0.01)
        // Stop positions hold: at 0.2 the second of three stops is reached.
        let shifted = BackgroundGradient(start: Vec2(0, 0), end: Vec2(1, 0), stops: [
            .init(color: RGBA(1, 0, 0), at: 0), .init(color: RGBA(0, 1, 0), at: 0.2), .init(color: RGBA(0, 1, 0), at: 1),
        ])
        let green = pixel(Backdrop.gradient(shifted, stage: Size2(width: 1920, height: 1080)), 600, 300)
        #expect(green[1] > 0.95 && green[0] < 0.02)
    }
}
