import CoreImage
import Testing
@testable import RegravaCore
@testable import RegravaRender

@Suite struct WallpaperTests {
    @Test func libraryFollowsTheBundledOrder() {
        let names = WallpaperLibrary.categories.map(\.name)
        #expect(names == ["macOS", "Spring", "Sunset", "Radiant", "Energy", "Iridescent", "Midnight", "Raycast"])
        let macOS = WallpaperLibrary.categories[0].wallpapers.map(\.name)
        #expect(macOS.prefix(3) == ["San Francisco Dark", "San Francisco Light", "Tahoe Light"])
        #expect(macOS.contains("iPad 17 Dark"))
        #expect(WallpaperLibrary.categories.first { $0.name == "Spring" }?.author?.name == "Black Pixel Studio")
    }

    @Test func idsResolveIncludingLegacyOnes() {
        #expect(WallpaperLibrary.url(for: BackgroundConfig.defaultWallpaper) != nil)
        #expect(WallpaperLibrary.url(for: "sonoma-from")?.lastPathComponent == "sonoma-from-above.jpg")
        #expect(WallpaperLibrary.url(for: "missing/none.jpg") == nil)
    }

    @Test func newProjectsUseTheDefaultWallpaper() {
        let background = FrameCompositor.makeBackground(BackgroundConfig(), canvas: Rect2(x: 0, y: 0, width: 320, height: 180), assetsDirectory: nil)
        #expect(background.extent == CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(BackgroundConfig().kind == .wallpaper)
    }

    @Test func multiStopGradientsKeepEveryStop() {
        let config = BackgroundConfig(kind: .gradient, gradientStops: [RGBA(hex: 0xFF0000), RGBA(hex: 0x00FF00), RGBA(hex: 0x0000FF)])
        let image = FrameCompositor.gradient(config, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 50, y: 50, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        #expect(pixel[1] > 0.8 && pixel[0] < 0.2)   // the middle is the green stop
    }
}
