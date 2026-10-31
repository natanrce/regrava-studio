import Foundation
import Testing
@testable import RegravaCore

private func click(_ t: Double, _ x: Double = 100, _ y: Double = 100) -> MouseEvent {
    MouseEvent(kind: .down, timeMs: t, position: Vec2(x, y))
}

private func move(_ t: Double, _ x: Double, _ y: Double) -> MouseEvent {
    MouseEvent(kind: .move, timeMs: t, position: Vec2(x, y))
}

@Suite struct IntervalTests {
    @Test func mergesOverlappingAndCloseSpans() {
        let merged = Intervals.merge([TimeSpan(8700, 11500), TimeSpan(4700, 7500), TimeSpan(20000, 21000)], gap: 2500)
        #expect(merged == [TimeSpan(4700, 11500), TimeSpan(20000, 21000)])
    }

    @Test func keepsDistantSpansApart() {
        let merged = Intervals.merge([TimeSpan(0, 100), TimeSpan(3000, 3100)], gap: 2500)
        #expect(merged.count == 2)
    }

    @Test func mergedSpanKeepsTheLaterEnd() {
        let merged = Intervals.merge([TimeSpan(0, 10000), TimeSpan(100, 200)])
        #expect(merged == [TimeSpan(0, 10000)])
    }
}

@Suite struct AutoZoomTests {
    @Test func clicksCloseTogetherBecomeOneZoom() {
        let zooms = AutoZoomGenerator.generate(events: [click(5000), click(9000)], durationMs: 20000, config: AutoZoomConfig())
        #expect(zooms.count == 1)
        #expect(zooms[0].startMs == 4700)
        #expect(zooms[0].endMs == 11500)
        #expect(zooms[0].isGenerated)
        #expect(zooms[0].scale == 2)
    }

    @Test func zoomNearTheStartBeginsAtOneMillisecond() {
        let zooms = AutoZoomGenerator.generate(events: [click(200.7)], durationMs: 20000, config: AutoZoomConfig())
        #expect(zooms.first?.startMs == 1)
        #expect(zooms.first?.endMs == 2700)
    }

    @Test func clicksInLastSecondAreIgnored() {
        let zooms = AutoZoomGenerator.generate(events: [click(19500)], durationMs: 20000, config: AutoZoomConfig())
        #expect(zooms.isEmpty)
    }

    @Test func zoomEndIsKeptAwayFromTheEnd() {
        let zooms = AutoZoomGenerator.generate(events: [click(18500)], durationMs: 20000, config: AutoZoomConfig())
        #expect(zooms.first?.endMs == 19200)
    }

    @Test func movesAndMouseUpsDoNotCreateZooms() {
        let events = [move(1000, 1, 1), MouseEvent(kind: .up, timeMs: 2000, position: .zero)]
        #expect(AutoZoomGenerator.generate(events: events, durationMs: 20000, config: AutoZoomConfig()).isEmpty)
    }

    @Test func disabledConfigProducesNothing() {
        var config = AutoZoomConfig()
        config.isEnabled = false
        #expect(AutoZoomGenerator.generate(events: [click(5000)], durationMs: 20000, config: config).isEmpty)
    }

    @Test func regenerationKeepsUserZooms() {
        let user = ZoomRange(startMs: 100, endMs: 900, mode: .manual)
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1000, height: 500), pointPixelScale: 1, durationMs: 20000, fps: 60),
            mouseEvents: [click(5000)],
            zooms: [user, ZoomRange(startMs: 50, endMs: 60, isGenerated: true)]
        )
        project.regenerateAutomaticZooms()
        #expect(project.zooms.count == 2)
        #expect(project.zooms.contains(user))
        #expect(project.zooms.contains { $0.isGenerated && $0.startMs == 4700 })
    }
}

@Suite struct MouseProcessingTests {
    @Test func removesIsolatedSpike() {
        let events = [move(0, 0, 0), move(10, 900, 900), move(20, 5, 5)]
        let cleaned = MouseProcessing.removeSpikes(events, threshold: 500)
        #expect(cleaned.map(\.timeMs) == [0, 20])
    }

    @Test func keepsRealLongMovement() {
        let events = [move(0, 0, 0), move(10, 900, 900), move(20, 1800, 1800)]
        #expect(MouseProcessing.removeSpikes(events, threshold: 500).count == 3)
    }

    @Test func downsampleKeepsClicks() {
        let events = [move(0, 0, 0), move(1, 2, 0), click(2, 3, 0), move(3, 30, 0)]
        let result = MouseProcessing.downsample(events, minDistance: 10)
        #expect(result.map(\.timeMs) == [0, 2, 3])
    }

    @Test func interpolatesPosition() {
        let events = [move(0, 0, 0), move(100, 100, 50)]
        #expect(MouseProcessing.position(at: 50, in: events) == Vec2(50, 25))
        #expect(MouseProcessing.position(at: -10, in: events) == Vec2(0, 0))
        #expect(MouseProcessing.position(at: 500, in: events) == Vec2(100, 50))
    }
}

@Suite struct GroupingTests {
    @Test func splitsWhenActivityLeavesTheVisibleArea() {
        let events = [move(0, 0, 0), move(100, 50, 50), move(200, 800, 800), move(300, 820, 790)]
        let groups = FocusGrouping.build(events: events, maxExtent: Size2(width: 200, height: 200))
        #expect(groups.count == 2)
        #expect(groups[0].finishedMs == 200)
        #expect(groups[1].startMs == 200)
        #expect(groups[1].finishedMs == nil)
    }

    @Test func centerIsWeightedByDwellTime() {
        // Stays 900 ms at x=100 and 100 ms at x=0.
        let center = FocusGrouping.dwellWeightedCenter([move(0, 0, 0), move(100, 100, 0)], finishedMs: 1000)
        #expect(abs(center.x - 90) < 1e-9)
    }

    @Test func lastEventOfTheOpenGroupWeighs100Ms() {
        // 3 s at x=0, then the last event counts 100 ms however long the zoom lasts.
        let events = [move(0, 0, 0), move(3000, 310, 0)]
        let groups = FocusGrouping.build(events: events, maxExtent: Size2(width: 1000, height: 1000))
        #expect(groups.count == 1)
        #expect(abs(groups[0].center.x - 310 * 0.1 / 3.1) < 1e-9)
        // A closed group's last event weighs until the next group starts; no 1 ms floor.
        let split = FocusGrouping.build(events: [move(0, 0, 0), move(0, 100, 0), move(500, 900, 0)], maxExtent: Size2(width: 200, height: 200))
        #expect(split[0].finishedMs == 500)
        #expect(abs(split[0].center.x - 100) < 1e-9)
    }

    @Test func picksStartedGroupOrFirstUpcoming() {
        let groups = FocusGrouping.build(
            events: [move(500, 0, 0), move(1000, 900, 0)],
            maxExtent: Size2(width: 100, height: 100)
        )
        #expect(FocusGrouping.group(at: 100, in: groups)?.startMs == 500)
        #expect(FocusGrouping.group(at: 1500, in: groups)?.startMs == 1000)
    }
}

@Suite struct SpringTests {
    @Test func settlesOnTarget() {
        var s = SpringValue(0)
        s.advance(toward: 100, config: .screen, milliseconds: 5000)
        #expect(s.value == 100)
        #expect(s.velocity == 0)
    }

    @Test func clampedSpringBarelyOvershootsAndKeepsVelocityContinuous() {
        var s = SpringValue(0)
        var peak = 0.0
        var velocityBeforeRest = 0.0
        for _ in 0..<300 {
            let before = s.velocity
            s.advance(toward: 100, config: .screen, milliseconds: 1000.0 / 60)
            peak = max(peak, s.value)
            if s.velocity == 0 && before != 0 { velocityBeforeRest = abs(before) }
        }
        #expect(peak <= 100.5)
        // The old "stop at the target" clamp zeroed hundreds of units/s in one frame; now the
        // spring eases in and only snaps once it is practically still.
        #expect(velocityBeforeRest < 1)
        #expect(s.value == 100)
    }

    @Test func unclampedSpringOvershoots() {
        var config = SpringConfig.screen
        config.clampOvershoot = false
        var s = SpringValue(0)
        var peak = 0.0
        for _ in 0..<300 {
            s.advance(toward: 100, config: config, milliseconds: 1000.0 / 60)
            peak = max(peak, s.value)
        }
        #expect(peak > 101)
    }

    @Test func clampRaisesDampingToCriticalOnlyWhenOvershooting() {
        let critical = 2 * (1.5 * 125.0).squareRoot()
        #expect(SpringMath.clampedDamping(stiffness: 125, mass: 1.5, damping: 12, value: 0, velocity: 5, target: 100) == 12)
        #expect(SpringMath.clampedDamping(stiffness: 125, mass: 1.5, damping: 12, value: 99, velocity: 500, target: 100) == critical)
        #expect(SpringMath.clampedDamping(stiffness: 125, mass: 1.5, damping: 12, value: 99, velocity: -500, target: 100) == 12)
    }

    @Test func precisionIsRelativeToTheMove() {
        #expect(SpringMath.relativePrecision(from: 0, to: 1000, precision: 0.002) == 2)
        #expect(SpringMath.relativePrecision(from: 0, to: 0.5, precision: 0.002) == 0.002)
        var tiny = SpringValue(0)
        for _ in 0..<600 { tiny.advance(toward: 0.5, config: .screen, milliseconds: 1000.0 / 60) }
        #expect(tiny.value == 0.5)
    }

    @Test func longStepsSnapAfterSettleTime() {
        let settle = SpringMath.settleTime(.screen)
        #expect(settle > 500 && settle < 20_000)
        var s = SpringValue(0)
        s.advance(toward: 100, config: .screen, milliseconds: settle)
        #expect(s.value == 100 && s.velocity == 0)
    }

    @Test func instantJumps() {
        var s = SpringValue(0)
        s.advance(toward: 42, config: .instant, milliseconds: 1)
        #expect(s.value == 42)
    }
}

@Suite struct GeometryTests {
    let rest = Rect2(x: 100, y: 100, width: 800, height: 400)
    let area = Rect2(x: 0, y: 0, width: 1000, height: 600)

    @Test func scaleOneCentresTheFittedScreen() {
        let r = rest.zoom(1, origin01: .center01, area: area)
        #expect(r.center == area.center && r.width == 800)
    }

    @Test func zoomedScreenCoversArea() {
        let r = rest.zoom(2, origin01: Vec2(0.9, 0.1), area: area)
        #expect(r.width == 1600)
        #expect(r.minX <= area.minX && r.maxX >= area.maxX)
        #expect(r.minY <= area.minY && r.maxY >= area.maxY)
    }

    @Test func centerFocusStaysCentered() {
        let r = rest.zoom(2, origin01: .center01, area: area)
        #expect(r.center == area.center)
    }
}

@Suite struct CameraTrackTests {
    func project(zooms: [ZoomRange], events: [MouseEvent]) -> Project {
        Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 10000, fps: 60),
            mouseEvents: events,
            zooms: zooms,
            style: StyleConfig(aspectRatio: 16.0 / 9, paddingRatio: 0.1)
        )
    }

    @Test func zoomsInDuringRangeAndBackOutAfter() {
        let p = project(zooms: [ZoomRange(startMs: 1000, endMs: 5000, scale: 2)], events: [move(0, 960, 540)])
        let track = CameraTrack(project: p)
        let rest = track.layout.restScreen
        #expect(track.frame(at: 500).screenRect == rest)
        #expect(abs(track.frame(at: 4500).screenRect.width - rest.width * 2) < 0.5)
        #expect(abs(track.frame(at: 9900).screenRect.width - rest.width) < 0.5)
    }

    @Test func followsTheActiveGroup() {
        let events = [move(0, 200, 200), move(3000, 1700, 900)]
        let p = project(zooms: [ZoomRange(startMs: 500, endMs: 6000, scale: 2)], events: events)
        let track = CameraTrack(project: p)
        let early = track.frame(at: 2900).screenRect
        let late = track.frame(at: 5900).screenRect
        // Looking at the top-left keeps the screen pushed right/down; looking bottom-right pushes it left/up.
        #expect(early.minX > late.minX)
        #expect(early.minY > late.minY)
    }

    @Test func manualZoomUsesTarget() {
        let zoom = ZoomRange(startMs: 0, endMs: 9000, scale: 3, mode: .manual, manualTarget: Vec2(0, 0))
        let track = CameraTrack(project: project(zooms: [zoom], events: []))
        let r = track.frame(at: 8000).screenRect
        // Pinned to the zoom area's top-left corner (the stage minus its padding).
        #expect(abs(r.minX - 90) < 0.5)
        #expect(abs(r.minY - 90) < 0.5)
    }

    @Test func disabledZoomIsIgnored() {
        let zoom = ZoomRange(startMs: 0, endMs: 9000, isDisabled: true)
        let track = CameraTrack(project: project(zooms: [zoom], events: []))
        #expect(track.frame(at: 5000).screenRect == track.layout.restScreen)
    }

    @Test func clickRippleIsReported() {
        let track = CameraTrack(project: project(zooms: [], events: [click(1000, 10, 10)]))
        #expect(track.frame(at: 1100).clickProgress != nil)
        #expect(track.frame(at: 2000).clickProgress == nil)
    }

    @Test func plainStageDropsZoomCursorAndClicks() {
        let p = project(zooms: [ZoomRange(startMs: 1000, endMs: 5000, scale: 2)], events: [move(0, 960, 540), click(3000, 960, 540)])
        let track = CameraTrack(project: p)
        #expect(abs(track.frame(at: 3100).screenRect.width - track.layout.restScreen.width * 2) < 0.5)
        let plain = track.plainFrame(at: 3100)
        #expect(plain.screenRect == track.layout.restScreen)
        #expect(plain.previousScreenRect == plain.screenRect)
        #expect(plain.cursorOpacity == 0)
        #expect(plain.clickProgress == nil)
        #expect(plain.loupe == nil)
        #expect(plain.cameraOpacity == 0)
    }

    @Test func plainStageFitsTheWholeScreen() {
        var p = project(zooms: [], events: [move(0, 960, 540)])
        // A stage narrower than the recording: "Avoid empty area" covers it, the plain stage fits it.
        p.style.aspectRatio = 1
        p.style.avoidEmptyZoomArea = true
        let track = CameraTrack(project: p)
        let covered = track.frame(at: 500).screenRect
        let fitted = track.plainFrame(at: 500).screenRect
        #expect(fitted.width < covered.width)
        // 1080 square stage padded by 0.1: a 900-wide zoom area holds the 16:9 screen.
        #expect(abs(fitted.width - 900 * track.layout.scale) < 0.5)
        #expect(abs(fitted.height - 506.25 * track.layout.scale) < 0.5)
    }
}

@Suite struct StoreTests {
    @Test func roundTripsProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".regrava")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = Project(
            recording: RecordingInfo(
                videoSize: Size2(width: 10, height: 10),
                pointPixelScale: 2,
                durationMs: 1000,
                fps: 30,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            mouseEvents: [click(10)]
        )
        p.style.background = BackgroundConfig(kind: .color, color: RGBA(1, 0, 0))
        try ProjectStore.save(p, to: dir)
        #expect(try ProjectStore.load(from: dir) == p)
    }
}


@Suite struct StyleAndCursorTests {
    @Test func autoCanvasIsRecordingPlusPadding() {
        let style = StyleConfig(aspectRatio: nil, paddingRatio: 0.1)
        let canvas = style.canvasSize(videoSize: Size2(width: 1600, height: 1000))
        let project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1600, height: 1000), pointPixelScale: 1, durationMs: 1000, fps: 60),
            mouseEvents: [],
            style: style
        )
        let layout = CanvasLayout(project: project)
        #expect(canvas.width == 1920)
        // Equal padding on every side.
        #expect(abs(layout.restScreen.minX - layout.restScreen.minY) < 1.5)
        #expect(abs((layout.canvas.width - layout.restScreen.maxX) - layout.restScreen.minX) < 1.5)
    }

    @Test func fixedAspectCanvas() {
        let vertical = StyleConfig(aspectRatio: 9.0 / 16).canvasSize(videoSize: Size2(width: 1920, height: 1080))
        #expect(vertical == Size2(width: 1080, height: 1920))
    }

    @Test func decodesProjectsSavedBeforeTheNewStyleModel() throws {
        let json = """
        {"formatVersion":1,"recording":{"videoFileName":"recording.mov","videoSize":{"width":100,"height":50},
        "pointPixelScale":2,"durationMs":1000,"fps":60,"createdAt":"2026-11-04T00:00:00Z"},
        "mouseEvents":[],"zooms":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","startMs":0,"endMs":500,"scale":2,
        "mode":"auto","manualTarget":{"x":0.5,"y":0.5},"isDisabled":false,"isInstant":false,"isGenerated":true}],
        "style":{"canvas":{"width":1920,"height":1080},"paddingRatio":0.08,"background":{"solid":{"_0":{"r":1,"g":0,"b":0,"a":1}}}},
        "cursor":{"isVisible":true,"sizeMultiplier":1.5},"animation":{"screenSpring":{"stiffness":125,"damping":12,"mass":1.5,"clampOvershoot":true,"precision":0.01},"startsZoomEarly":false},
        "autoZoom":{"leadMs":300,"holdMs":2500,"ignoreClicksInLastMs":1000,"endMarginMs":800,"mergeGapMs":2500,"scale":2,"isEnabled":true}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))
        #expect(project.style.paddingRatio == 0.08)
        #expect(project.style.background.kind == .wallpaper)
        #expect(project.cursor.size == 48)
        #expect(project.zooms.first?.presentation == .screen)
        #expect(project.markersMs.isEmpty)
    }

    private let events = [
        MouseEvent(kind: .move, timeMs: 0, position: Vec2(10, 10)),
        MouseEvent(kind: .move, timeMs: 1000, position: Vec2(500, 500)),
    ]

    @Test func loopReturnsCursorToStart() {
        var config = CursorConfig()
        config.loopPositionBeforeEndMs = 1000
        let points = CameraTrack.cursorPathEvents(events: events, resolver: TimeResolver(slices: Project.defaultSlices(durationMs: 5000)), config: config)
        #expect(points.map(\.timeMs) == [0, 1000, 1001])
        #expect(points.last?.position == Vec2(10, 10))
        let early = CameraTrack.cursorPathEvents(events: events, resolver: TimeResolver(slices: Project.defaultSlices(durationMs: 1500)), config: config)
        #expect(early.map(\.timeMs) == [0, 1])
    }

    @Test func stopMovementDoesNotChangeThePath() {
        // StopMovementInLastPartMs is never read.
        var config = CursorConfig()
        config.stopMovementInLastPartMs = 600
        let points = CameraTrack.cursorPathEvents(events: events, resolver: TimeResolver(slices: Project.defaultSlices(durationMs: 1000)), config: config)
        #expect(points.map(\.timeMs) == [0, 1000])
    }

    @Test func firstSampleStartsThePath() {
        let late = [MouseEvent(kind: .move, timeMs: 700, position: Vec2(5, 5))]
        let points = CameraTrack.cursorPathEvents(events: late, resolver: TimeResolver(slices: Project.defaultSlices(durationMs: 2000)), config: CursorConfig())
        #expect(points.first?.timeMs == 0)
        #expect(points.first?.position == Vec2(5, 5))
    }

    @Test func idleCursorHidesAfterTheDelay() {
        #expect(CameraTrack.isCursorVisible(at: 2900, pathEvents: events, hideAfterMs: 2000))
        #expect(!CameraTrack.isCursorVisible(at: 3100, pathEvents: events, hideAfterMs: 2000))
        #expect(CameraTrack.isCursorVisible(at: 9000, pathEvents: events, hideAfterMs: nil))
    }

    @Test func idleCursorFadesOnTheVisibilitySpring() {
        var config = CursorConfig()
        config.hideNotMovingAfterMs = 2000
        let project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 6000, fps: 60),
            mouseEvents: events,
            cursor: config
        )
        let track = CameraTrack(project: project)
        #expect(track.frame(at: 2900).cursorOpacity == 1)
        let fading = track.frame(at: 3150).cursorOpacity
        #expect(fading > 0 && fading < 1)
        #expect(track.frame(at: 5500).cursorOpacity < 0.01)
    }

    @Test func loupeZoomsDoNotMoveTheScreen() {
        let project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 4000, fps: 60),
            mouseEvents: events,
            zooms: [ZoomRange(startMs: 0, endMs: 3900, presentation: .loupe)]
        )
        let track = CameraTrack(project: project)
        #expect(track.frame(at: 2000).screenRect == track.layout.restScreen)
    }
}
