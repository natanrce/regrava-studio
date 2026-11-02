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

    private func layout(_ background: BackgroundConfig) -> CanvasLayout {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        p.style.background = background
        return CanvasLayout(project: p)
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

    /// An image or wallpaper background without a file shows the plain colour.
    @Test func missingImagesFallBackToTheColour() {
        var config = BackgroundConfig(kind: .image, color: RGBA(0, 1, 0))
        config.imageFileName = "missing.png"
        let backdrop = Backdrop(config, layout: layout(config), assetsDirectory: nil)
        let canvas = layout(config).canvas
        let image = backdrop.image(bounds: canvas, radius: 0)
        #expect(image.extent == CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        let p = pixel(image, 100, 100)
        #expect(p[1] > 0.99 && p[0] < 0.01)
        config.kind = .unsplash
        #expect(pixel(Backdrop(config, layout: layout(config), assetsDirectory: nil).image(bounds: canvas, radius: 0), 5, 5)[1] > 0.99)
        config.kind = .wallpaper
        config.systemName = "missing/none.jpg"
        #expect(pixel(Backdrop(config, layout: layout(config), assetsDirectory: nil).image(bounds: canvas, radius: 0), 5, 5)[1] > 0.99)
    }

    /// The background covers its rect: a larger rect magnifies the texture around it.
    @Test func theBackgroundCoversItsRect() {
        let gradient = BackgroundGradient(start: Vec2(0, 0), end: Vec2(1, 0), stops: [.init(color: RGBA(0, 0, 0), at: 0), .init(color: RGBA(1, 1, 1), at: 1)])
        let config = BackgroundConfig(kind: .gradient, gradient: gradient)
        let l = layout(config)
        let backdrop = Backdrop(config, layout: l, assetsDirectory: nil)
        let canvas = l.canvas
        // Twice as wide, starting at x = 0: the middle of the canvas is a quarter along.
        let wide = backdrop.image(bounds: Rect2(x: 0, y: 0, width: canvas.width * 2, height: canvas.height * 2), radius: 0)
        let atRest = backdrop.image(bounds: canvas, radius: 0)
        let quarter = pixel(atRest, canvas.width / 4, 100)[0]
        #expect(abs(pixel(wide, canvas.width / 2, canvas.height - 1)[0] - quarter) < 0.01)
        // The same placement is drawn once.
        #expect(backdrop.image(bounds: canvas, radius: 0) === atRest)
    }

    @Test func newProjectsUseTheDefaultWallpaper() {
        let config = BackgroundConfig()
        #expect(config.kind == .wallpaper)
        let l = layout(config)
        let image = Backdrop(config, layout: l, assetsDirectory: nil).image(bounds: l.canvas, radius: 0)
        #expect(image.extent == CGRect(x: 0, y: 0, width: l.canvas.width, height: l.canvas.height))
    }
}
