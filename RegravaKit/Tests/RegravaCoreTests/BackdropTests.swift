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

    /// While a 2× zoom moves the screen the background covers the stage scaled by 1.125
    /// around the zoom point, rounded outward, and blurs by 8 × 2 stage px; the loupe adds a
    /// frost of 0.5 % of the stage width.
    @Test func zoomGrowsAndBlursTheBackground() throws {
        let p = project([ZoomRange(startMs: 2000, endMs: 8000, scale: 2, mode: .manual, manualTarget: Vec2(0.25, 0.75))])
        let planner = CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, pathEvents: p.mouseEvents)
        let layout = CanvasLayout(project: p)
        let stage = Rect2(x: 0, y: 0, width: layout.canvas.width / layout.scale, height: layout.canvas.height / layout.scale)
        let during = planner.backdropTarget(at: 5000, loupeActive: false, stage: stage)
        let k = 1.125
        let x = (0.25 * stage.width * (1 - k)).rounded(.down), y = (0.75 * stage.height * (1 - k)).rounded(.down)
        #expect(during.rect == Rect2(x: x, y: y, width: (stage.width * k).rounded(.up), height: (stage.height * k).rounded(.up)))
        #expect(during.blurRadius == 16)
        #expect(planner.backdropTarget(at: 500, loupeActive: false, stage: stage) == BackdropTarget(rect: stage, blurRadius: 0, frostBlurRadius: 0))
        #expect(abs(planner.backdropTarget(at: 500, loupeActive: true, stage: stage).frostBlurRadius - stage.width * 0.005) < 1e-9)

        // The style's own blur wins over the zoom's.
        let blurred = project(p.zooms, blur: 50)
        let blurredPlanner = CameraPlanner(project: blurred, timeline: LayoutTimeline(project: blurred), cleaned: p.mouseEvents, pathEvents: p.mouseEvents)
        #expect(abs(blurredPlanner.backdropTarget(at: 5000, loupeActive: false, stage: stage).blurRadius - stage.width * 0.025) < 1e-9)

        // The track springs toward it with the screen movement spring.
        let track = CameraTrack(project: p)
        let settled = track.frame(at: 7000)
        let rect = try #require(settled.backgroundRect)
        let target = track.layout.toCanvas(during.rect)
        #expect(abs(rect.x - target.x) < 0.5 && abs(rect.width - target.width) < 0.5)
        #expect(abs((settled.backgroundBlurRadius ?? 0) - 16) < 0.05)
        let rest = track.frame(at: 200)
        let restRect = try #require(rest.backgroundRect)
        #expect(abs(restRect.x) < 1e-6 && abs(restRect.width - track.layout.canvas.width) < 1e-6, "\(restRect) \(track.layout.canvas)")
        #expect(rest.backgroundBlurRadius == 0)
        // Halfway into the zoom the spring is still moving.
        let moving = track.frame(at: 2100)
        #expect((moving.backgroundRect?.width ?? 0) > track.layout.canvas.width && (moving.backgroundRect?.width ?? 0) < target.width - 0.5)
    }
}
