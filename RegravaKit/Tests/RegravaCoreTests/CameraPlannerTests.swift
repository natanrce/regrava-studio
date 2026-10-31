import Testing
@testable import RegravaCore

/// Which zoom moves the screen, and how auto zooms find their focus.
@Suite struct CameraPlannerTests {
    func project(_ zooms: [ZoomRange], events: [MouseEvent] = [MouseEvent(kind: .move, timeMs: 0, position: Vec2(960, 540))]) -> Project {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 20_000, fps: 60), mouseEvents: events)
        p.zooms = zooms
        p.animation.startsZoomEarly = true
        return p
    }

    func planner(_ p: Project) -> CameraPlanner {
        CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, sparse: p.mouseEvents)
    }

    @Test func aDisabledZoomDoesNotBlockTheNextLeadIn() {
        let next = ZoomRange(startMs: 2100, endMs: 4000)
        let p = project([ZoomRange(startMs: 1000, endMs: 2000, isDisabled: true), next])
        #expect(planner(p).activeZoom(at: 1900) == next)
        // An enabled loupe holding the time still blocks it.
        let q = project([ZoomRange(startMs: 1000, endMs: 2000, presentation: .loupe), next])
        #expect(planner(q).activeZoom(at: 1900) == nil)
        #expect(planner(q).activeZoom(at: 2050) == next)
    }
}
