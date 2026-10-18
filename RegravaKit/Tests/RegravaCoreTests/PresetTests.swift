import Foundation
import Testing
@testable import RegravaCore

@Suite struct PresetTests {
    @Test func presetCarriesTheProjectSettings() throws {
        var source = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 5000, fps: 60), mouseEvents: [])
        source.style.paddingRatio = 0.2
        source.cursor.size = 80
        source.animation.motionBlurAmount = 0.4
        source.audio.backgroundAudioFileName = "music.m4a"
        source.style.background.imageFileName = "background-1.png"
        let preset = Preset(name: "Mine", config: source.presetConfig)
        let decoded = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
        #expect(Set(decoded.config.assetFileNames) == ["music.m4a", "background-1.png"])

        var target = Project(recording: RecordingInfo(videoSize: Size2(width: 1280, height: 720), pointPixelScale: 2, durationMs: 9000, fps: 30), mouseEvents: [])
        target.apply(decoded.config)
        #expect(target.presetConfig == source.presetConfig)
        #expect(target.recording.durationMs == 9000)
    }
}
