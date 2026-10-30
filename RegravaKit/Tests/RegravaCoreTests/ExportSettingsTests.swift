import Testing
@testable import RegravaCore

@Suite struct ExportSettingsTests {
    @Test func defaultsPerFormat() {
        #expect(ExportSettings.defaults(for: .mp4).summary() == "MP4 • 720p • 60fps • Social Media")
        #expect(ExportSettings.defaults(for: .gif).summary() == "GIF • 480p • 15fps • Social Media")
        #expect(ExportSettings.defaults(for: .prores).summary() == "ProRes • 422 HQ • 1080p • 60fps")
        #expect(ExportSettingsStore().current.format == .mp4)
        #expect(ExportSettingsStore().preferredTarget == .file)
    }

    @Test func webQualityCapsResolutionAt1080() {
        var s = ExportSettings.defaults(for: .mp4)
        s.height = 2160
        s.quality = .webLow
        #expect(s.allowedResolutions == [720, 1080])
        #expect(s.normalized().height == 1080)
    }

    @Test func snapsToNearestLowerOption() {
        var s = ExportSettings.defaults(for: .gif)
        s.fps = 60
        s.height = 2160
        let n = s.normalized()
        #expect(n.fps == 50)
        #expect(n.height == 1080)
        s.fps = 5
        #expect(s.normalized().fps == 50)
    }

    @Test func bothCodecOnlyForFiles() {
        var s = ExportSettings.defaults(for: .mp4)
        s.codec = .both
        #expect(s.normalized(target: .file).codec == .both)
        #expect(s.normalized(target: .clipboard).codec == .h264)
        #expect(s.summary() == "MP4 • H.264 + HEVC • 720p • 60fps • Social Media")
    }

    @Test func outputSizeKeepsCanvasAspectWithEvenWidth() {
        let size = ExportSettings.defaults(for: .mp4).outputSize(aspectRatio: 16.0 / 9)
        #expect(size == Size2(width: 1280, height: 720))
    }

    @Test func outputSizeFloorsToEvenPixels() {
        #expect(ExportSettings.outputSize(aspectRatio: 9.0 / 16, height: 2160) == Size2(width: 1214, height: 2160))
        #expect(ExportSettings.outputSize(aspectRatio: 4.0 / 3, height: 1080) == Size2(width: 1440, height: 1080))
        #expect(ExportSettings.evenPixels(1214.9999999) == 1214)
        #expect(ExportSettings.evenPixels(1215.0000000001) == 1214)
        #expect(ExportSettings.evenPixels(1215.9999999999) == 1216)
        #expect(ExportSettings.evenPixels(0.5) == 2)
    }

    @Test func outputSizeFitsInside4K() {
        #expect(ExportSettings.outputSize(aspectRatio: 21.0 / 9, height: 2160) == Size2(width: 3840, height: 1644))
        #expect(ExportSettings.outputSize(aspectRatio: 1, height: 2160) == Size2(width: 2160, height: 2160))
        #expect(ExportSettings.outputSize(aspectRatio: 21.0 / 9, height: 1080) == Size2(width: 2520, height: 1080))
    }

    @Test func storeRemembersSettingsPerFormat() {
        var store = ExportSettingsStore()
        var gif = store.perFormat[.gif]!
        gif.fps = 30
        store.current = gif
        store.select(format: .mp4)
        #expect(store.current.fps == 60)
        store.select(format: .gif)
        #expect(store.current.fps == 30)
    }
}
