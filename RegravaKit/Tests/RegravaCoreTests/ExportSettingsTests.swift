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
        let size = ExportSettings.defaults(for: .mp4).outputSize(canvas: Size2(width: 1920, height: 1080))
        #expect(size == Size2(width: 1280, height: 720))
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
