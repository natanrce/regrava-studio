import Testing
@testable import RegravaCore

@Suite struct CursorTypeTests {
    private func event(_ kind: MouseEventKind, _ t: Double, _ id: String?) -> MouseEvent {
        MouseEvent(kind: kind, timeMs: t, position: Vec2(t, 0), cursorID: id)
    }

    @Test func recordedIDsMapToImageNames() {
        #expect(CursorTypes.assetName(for: "arrow") == "pointer")
        #expect(CursorTypes.assetName(for: nil) == "pointer")
        #expect(CursorTypes.assetName(for: "pointingHand") == "pointinghand")
        #expect(CursorTypes.assetName(for: "iBeam") == "ibeamstroke")
        #expect(CursorTypes.assetName(for: "custom-2") == "custom-2")
        #expect(CursorTypes.assetName(for: "somethingElse") == "pointer")
    }

    @Test func withoutOptimizationEveryChangeShows() {
        let events = [event(.move, 0, "arrow"), event(.move, 100, "pointingHand"), event(.move, 200, "arrow")]
        var config = CursorConfig()
        config.optimizeOriginalTypes = false
        let types = CursorTypes.typeEvents(events, config: config)
        #expect(CursorTypes.assetName(at: 150, typeEvents: types, config: config) == "pointinghand")
        #expect(CursorTypes.imageChangeTimes(types, config: config) == [100, 200])
    }

    @Test func optimizationKeepsOnlyChangesThatLeadToAClick() {
        let events = [
            event(.move, 0, "arrow"),
            event(.move, 100, "pointingHand"), // hovered a link without clicking
            event(.move, 200, "arrow"),
            event(.move, 300, "iBeam"),        // text field: clicked below
            event(.move, 350, "iBeam"),
            event(.down, 400, "iBeam"),
            event(.up, 450, "iBeam"),
            event(.move, 900, "arrow"),        // moved on > 250 ms after the release
        ]
        let config = CursorConfig()
        let types = CursorTypes.typeEvents(events, config: config)
        // The hover over the link is gone; the I-beam starts where it first appeared.
        #expect(CursorTypes.assetName(at: 150, typeEvents: types, config: config) == "pointer")
        #expect(CursorTypes.assetName(at: 320, typeEvents: types, config: config) == "ibeamstroke")
        #expect(CursorTypes.assetName(at: 600, typeEvents: types, config: config) == "ibeamstroke")
        #expect(CursorTypes.assetName(at: 950, typeEvents: types, config: config) == "pointer")
    }

    @Test func alwaysUsePointer() {
        var config = CursorConfig()
        config.alwaysUseDefault = true
        config.optimizeOriginalTypes = false
        let types = CursorTypes.typeEvents([event(.move, 0, "iBeam")], config: config)
        #expect(CursorTypes.assetName(at: 10, typeEvents: types, config: config) == "pointer")
        #expect(CursorTypes.imageChangeTimes(types, config: config).isEmpty)
    }

    @Test func pressIsAnticipatedWithSmoothMovement() {
        let events = [event(.move, 0, nil), event(.down, 1000, nil), event(.up, 1800, nil)]
        let clicks = events.filter(\.isClick)
        #expect(!CursorTypes.isPressed(at: 400, events: events, clicks: clicks, smoothed: true))
        #expect(CursorTypes.isPressed(at: 600, events: events, clicks: clicks, smoothed: true))
        #expect(!CursorTypes.isPressed(at: 600, events: events, clicks: clicks, smoothed: false))
        #expect(CursorTypes.isPressed(at: 1200, events: events, clicks: clicks, smoothed: true))
        // Within 500 ms of the release the cursor already looks released.
        #expect(!CursorTypes.isPressed(at: 1400, events: events, clicks: clicks, smoothed: true))
    }

    @Test func trackReportsTypeAndPressScale() {
        let events = [event(.move, 0, "arrow"), event(.move, 500, "pointingHand"), event(.down, 1000, "pointingHand"), event(.up, 2500, "pointingHand")]
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 4000, fps: 60),
            mouseEvents: events
        )
        project.zooms = []
        let track = CameraTrack(project: project)
        #expect(track.frame(at: 200).cursorName == "pointer")
        #expect(track.frame(at: 1500).cursorName == "pointinghand")
        #expect(abs(track.frame(at: 1900).cursorScale - CameraTrack.pressedCursorScale) < 0.01)
        #expect(track.frame(at: 3900).cursorScale == 1)
    }
}
