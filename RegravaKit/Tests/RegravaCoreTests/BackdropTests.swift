import Foundation
import Testing
@testable import RegravaCore

@Suite struct BackdropTests {
    private func project(_ zooms: [ZoomRange], blur: Double = 0) -> Project {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 12_000, fps: 60), mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(960, 540))])
        p.zooms = zooms
        p.style.background.blur = blur
        return p
    }

    /// stageWidth × blur / 100 × 0.05: 48 stage px for blur 50 on a 1920 px wide stage.
    @Test func styleBlurIsAShareOfTheStageWidth() {
        var config = BackgroundConfig()
        #expect(config.blurRadius(stageWidth: 1920) == 0)
        config.blur = 50
        #expect(abs(config.blurRadius(stageWidth: 1920) - 48) < 1e-9)
        config.blur = 100
        #expect(abs(config.blurRadius(stageWidth: 1080) - 54) < 1e-9)
    }
}
