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
        let groups = FocusGrouping.build(events: events, maxExtent: Size2(width: 200, height: 200), endMs: 1000)
        #expect(groups.count == 2)
        #expect(groups[0].endMs == 200)
        #expect(groups[1].startMs == 200)
        #expect(groups[1].endMs == 1000)
    }

    @Test func centerIsWeightedByDwellTime() {
        // Stays 900 ms at x=100 and 100 ms at x=0.
        let center = FocusGrouping.dwellWeightedCenter([move(0, 0, 0), move(100, 100, 0)], endMs: 1000)
        #expect(abs(center.x - 90) < 1e-9)
    }

    @Test func picksStartedGroupOrFirstUpcoming() {
        let groups = FocusGrouping.build(
            events: [move(500, 0, 0), move(1000, 900, 0)],
            maxExtent: Size2(width: 100, height: 100),
            endMs: 2000
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

    @Test func clampedSpringNeverOvershoots() {
        var s = SpringValue(0)
        var peak = 0.0
        for _ in 0..<3000 {
            s.advance(toward: 100, config: .screen, milliseconds: 1)
            peak = max(peak, s.value)
        }
        #expect(peak <= 100)
    }

    @Test func instantJumps() {
        var s = SpringValue(0)
        s.advance(toward: 42, config: .instant, milliseconds: 1)
        #expect(s.value == 42)
    }
}

@Suite struct GeometryTests {
    let rest = Rect2(x: 100, y: 100, width: 800, height: 400)
    let canvas = Rect2(x: 0, y: 0, width: 1000, height: 600)

    @Test func scaleOneIsRest() {
        #expect(ZoomGeometry.zoomedScreenRect(rest: rest, scale: 1, focus: .center01, area: canvas) == rest)
    }

    @Test func zoomedScreenCoversArea() {
        let r = ZoomGeometry.zoomedScreenRect(rest: rest, scale: 2, focus: Vec2(0.9, 0.1), area: canvas)
        #expect(r.width == 1600)
        #expect(r.minX <= canvas.minX && r.maxX >= canvas.maxX)
        #expect(r.minY <= canvas.minY && r.maxY >= canvas.maxY)
    }

    @Test func centerFocusStaysCentered() {
        let r = ZoomGeometry.zoomedScreenRect(rest: rest, scale: 2, focus: .center01, area: canvas)
        #expect(r.center == canvas.center)
    }
}

@Suite struct CameraTrackTests {
    func project(zooms: [ZoomRange], events: [MouseEvent]) -> Project {
        Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 10000, fps: 60),
            mouseEvents: events,
            zooms: zooms,
            style: StyleConfig(canvas: Size2(width: 1920, height: 1080), paddingRatio: 0.1)
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
        #expect(abs(r.minX - track.layout.canvas.minX) < 0.5)
        #expect(abs(r.minY - track.layout.canvas.minY) < 0.5)
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
        p.style.background = .solid(RGBA(1, 0, 0))
        try ProjectStore.save(p, to: dir)
        #expect(try ProjectStore.load(from: dir) == p)
    }
}
