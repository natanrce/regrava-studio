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
}
