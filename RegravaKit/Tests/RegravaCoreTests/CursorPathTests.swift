import Testing
@testable import RegravaCore

@Suite struct CursorPathTests {
    /// Rests at the origin, sweeps 800 px right between 1000 and 1200 ms, then clicks.
    private func sweep(clickAt clickMs: Double = 1210) -> (points: [CursorPathPoint], sync: [CursorSyncPoint]) {
        var points = [CursorPathPoint(timeMs: 0, position: Vec2(0, 0))]
        var t = 1000.0
        while t <= 1200 {
            points.append(CursorPathPoint(timeMs: t, position: Vec2((t - 1000) * 4, 0)))
            t += 8
        }
        let sync = [CursorSyncPoint(timeMs: clickMs, reason: .click, tolerance: 2)]
        return (points, sync)
    }

    @Test func searchHelpersFindTheRightIndex() {
        let keys: [Double] = [0, 10, 10, 20]
        #expect(floorSearch(count: 4, value: 10) { keys[$0] } == 1)
        #expect(floorSearch(count: 4, value: 15) { keys[$0] } == 2)
        #expect(floorSearch(count: 4, value: -1) { keys[$0] } == nil)
        #expect(ceilSearch(count: 4, value: 11) { keys[$0] } == 3)
        #expect(ceilSearch(count: 4, value: 21) { keys[$0] } == nil)
    }

    @Test func recordedPathDoesNotInterpolateAcrossGaps() {
        let path = RecordedCursorPath(points: [
            CursorPathPoint(timeMs: 0, position: Vec2(0, 0)),
            CursorPathPoint(timeMs: 20, position: Vec2(20, 0)),
            CursorPathPoint(timeMs: 500, position: Vec2(100, 0)),
        ])
        #expect(path.position(at: 10) == Vec2(10, 0))
        // 480 ms apart: the cursor held still, then jumped.
        #expect(path.position(at: 300) == Vec2(20, 0))
        #expect(path.isStill(between: 100, and: 400))
        #expect(!path.isStill(between: 5, and: 15))
    }

    @Test func withoutSpringFollowsTheRecording() {
        let (points, sync) = sweep()
        let path = SmoothedCursorPath.plan(points: points, syncPoints: sync, spring: nil, durationMs: 2000)
        #expect(path.position(at: 1100) == Vec2(400, 0))
        #expect(path.position(at: 1500) == Vec2(800, 0))
    }

    @Test func smoothedCursorReachesClicksOnTime() {
        let (points, sync) = sweep()
        let planned = SmoothedCursorPath.plan(points: points, syncPoints: sync, spring: .cursor, durationMs: 2000)
        let plain = SmoothedCursorPath.plan(points: points, syncPoints: [], spring: .cursor, durationMs: 2000)
        let real = Vec2(800, 0)
        // A plain spring is still far behind when the click happens...
        #expect(plain.position(at: 1210).distance(to: real) > 50)
        // ...the planned one arrives within the click tolerance (2 pt).
        #expect(planned.position(at: 1210).distance(to: real) <= 2)
        // And both come to rest on the recording.
        #expect(planned.position(at: 1990).distance(to: real) < 0.5)
    }

    @Test func plannedMotionIsContinuous() {
        let (points, sync) = sweep()
        let planned = SmoothedCursorPath.plan(points: points, syncPoints: sync, spring: .cursor, durationMs: 2000)
        var previous = planned.position(at: 0)
        var largestStep = 0.0
        var t = 1.0
        while t <= 2000 {
            let p = planned.position(at: t)
            largestStep = max(largestStep, p.distance(to: previous))
            previous = p
            t += 1
        }
        // The recording moves 4 px/ms; the drawn cursor never teleports.
        #expect(largestStep < 12)
    }
}
