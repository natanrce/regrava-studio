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
        CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, pathEvents: CameraTrack.cursorPathEvents(events: p.mouseEvents, resolver: p.resolver, config: p.cursor))
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

extension CameraPlannerTests {
    @Test func aOneTimesZoomStillMovesTheScreen() {
        let zoom = ZoomRange(startMs: 1000, endMs: 3000, scale: 1)
        #expect(planner(project([zoom])).activeZoom(at: 2000) == zoom)
    }

    @Test func fullscreenCameraCarriesTheZoomThatEndedLast() {
        var p = project([ZoomRange(startMs: 1000, endMs: 3000), ZoomRange(startMs: 2000, endMs: 3500, isDisabled: true)])
        p.recording.cameraFileName = "camera.mov"
        p.cameraLayouts = [CameraLayoutRange(startMs: 3000, endMs: 7000, type: .fullscreenCamera)]
        // The disabled zoom ended last, so it is the one carried until 85% of the range.
        #expect(planner(p).activeZoom(at: 4000) == p.zooms[1])
        #expect(planner(p).activeZoom(at: 6500) == nil)
        // A loupe ending last carries nothing, even with a screen zoom before it.
        var q = p
        q.zooms[1] = ZoomRange(startMs: 2000, endMs: 3500, presentation: .loupe)
        #expect(planner(q).activeZoom(at: 4000) == nil)
    }
}

extension CameraPlannerTests {
    @Test func anInstantLoupeSnapsTheScreen() {
        let p = project([ZoomRange(startMs: 1000, endMs: 3000, isInstant: true, presentation: .loupe)])
        #expect(planner(p).isInInstantWindow(3050))
        #expect(!planner(p).isInInstantWindow(3051))
        let disabled = project([ZoomRange(startMs: 1000, endMs: 3000, isDisabled: true, isInstant: true)])
        #expect(!planner(disabled).isInInstantWindow(2000))
    }
}

extension CameraPlannerTests {
    func move(_ t: Double, _ x: Double, _ y: Double) -> MouseEvent { MouseEvent(kind: .move, timeMs: t, position: Vec2(x, y)) }

    @Test func autoZoomGroupsUseOnlyEventsInsideTheZoom() {
        // The cursor before the zoom is not carried in; an event right at the start is also
        // counted 1 ms before it.
        let zoom = ZoomRange(startMs: 1000, endMs: 5000)
        let p = project([zoom], events: [move(0, 100, 100), move(1000, 1500, 800), move(2000, 1510, 800)])
        let groups = planner(p).groups[zoom.id] ?? []
        #expect(groups.map(\.startMs) == [999])
        #expect(abs(groups[0].center.x - (1500 * 1.001 + 1510 * 0.1) / 1.101) < 1e-9)
    }

    @Test func autoZoomWithoutEventsLooksNearItsStart() {
        let zoom = ZoomRange(startMs: 1000, endMs: 5000)
        let events = [move(0, 100, 100), MouseEvent(kind: .down, timeMs: 6000, position: Vec2(900, 900))]
        // Without smoothing: the event at or before the start.
        var p = project([zoom], events: events)
        p.animation.mouseSpring = nil
        #expect(planner(p).groups[zoom.id]?.map(\.center) == [Vec2(100, 100)])
        // With smoothing, a press within 500 ms after the start wins.
        let early = ZoomRange(startMs: 5600, endMs: 5900)
        var q = project([early], events: events)
        q.animation.mouseSpring = SpringConfig(stiffness: 470, damping: 70, mass: 3)
        #expect(planner(q).groups[early.id]?.map(\.center) == [Vec2(900, 900)])
    }
}
