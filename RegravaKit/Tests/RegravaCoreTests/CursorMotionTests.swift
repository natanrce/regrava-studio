import Foundation
import Testing
@testable import RegravaCore

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

/// 101 moves 16 ms apart: right at 1.2 px/ms, then left at 0.4 px/ms, drifting down.
private let sweep: [MouseEvent] = (0...100).map { i in
    let t = Double(i) * 16
    return MouseEvent(kind: .move, timeMs: t, position: Vec2(100 + t * (i < 50 ? 1.2 : -0.4), 300 + Double(i) * 5))
}
private let probes: [Double] = [0, 400, 600, 800, 1200, 1600, 2400]

@Suite struct CursorRotationTests {
    @Test func tiltMatchesReferenceValues() {
        let keyframes = CursorRotation.tiltKeyframes(sweep, ratio: 0.5)
        let expected = [0.12566370614359174, 0.12566370614359174, 0.12566370614359174, -0.3490658503988659, -0.07321658713446512, -0.04300552135122146, 0]
        #expect(keyframes.count == 63)
        for (t, value) in zip(probes, expected) { #expect(near(CursorRotation.rotation(at: t, in: keyframes), value), "t = \(t)") }
    }

    @Test func followMatchesReferenceValues() {
        let keyframes = CursorRotation.followKeyframes(sweep)
        let expected = [2.218253710929515, 2.218253710929515, 2.218253710929515, 2.226625626781035, 2.356194490192345, 2.356194490192345, 2.356194490192345]
        #expect(keyframes.count == 13)
        for (t, value) in zip(probes, expected) { #expect(near(CursorRotation.rotation(at: t, in: keyframes), value), "t = \(t)") }
    }

    @Test func followContinuesAGivenHeading() {
        let keyframes = CursorRotation.followKeyframes(sweep, startRotationRad: 0.3)
        let expected = [2.1460599508527776, 2.1460599508527776, 2.2692989880868044, 2.2914669429247625, 2.356194490192345, 2.356194490192345, 2.356194490192345]
        for (t, value) in zip(probes, expected) { #expect(near(CursorRotation.rotation(at: t, in: keyframes), value), "t = \(t)") }
    }

    @Test func noTiltWithoutAmount() {
        #expect(CursorRotation.tiltKeyframes(sweep, ratio: 0).isEmpty)
        #expect(CursorRotation.rotation(at: 500, in: []) == 0)
    }

    @Test func springFollowsTheMode() {
        #expect(CursorRotation.spring(for: .velocity) == SpringConfig(stiffness: 120, damping: 8, mass: 1))
        #expect(CursorRotation.spring(for: .directional) == SpringConfig(stiffness: 320, damping: 28, mass: 1))
    }

    @Test func tiltIsOnByDefault() throws {
        let config = try JSONDecoder().decode(CursorConfig.self, from: Data("{}".utf8))
        #expect(config.rotationMode == .velocity)
        #expect(config.rotateOnXMovementRatio == 0.5)
        let follow = try JSONDecoder().decode(CursorConfig.self, from: Data(#"{"rotationMode":"directional","rotateOnXMovementRatio":1.5}"#.utf8))
        #expect(follow.rotationMode == .directional)
        #expect(follow.rotateOnXMovementRatio == 1.5)
    }

    @Test func trackTiltsAMovingCursor() {
        let project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 4000, fps: 60),
            mouseEvents: sweep
        )
        let track = CameraTrack(project: project)
        // Sprung toward the keyframes: leaning left while moving left, upright long after.
        #expect(track.frame(at: 900).cursorRotationRad < -0.05)
        #expect(abs(track.frame(at: 3900).cursorRotationRad) < 0.01)
    }
}

@Suite struct CursorPlanTests {
    func plan(events: [MouseEvent], durationMs: Double, spring: SpringConfig? = .cursor) -> CursorPlan {
        CursorPlan(inputs: CursorPlan.Inputs(
            pathEvents: events, cleanedEvents: events, imageChangesMs: [], hoverTimesMs: [],
            slices: Project.defaultSlices(durationMs: durationMs), spring: spring, pointPixelScale: 1,
            rotationMode: .velocity, rotateOnXMovementRatio: 0.5
        ))
    }

    @Test func chunksArePlannedAroundTheirOwnWindow() {
        let settle = SpringMath.settleTime(.cursor)
        let w = plan(events: [], durationMs: 30000).window(1)
        #expect(w.startMs == 10000)
        #expect(near(w.fromMs, 10000 - settle - 2100))
        #expect(w.toMs == 22100)
    }

    @Test func noSmoothingPlansWithTheDefaultSpringsSettleTime() {
        let w = plan(events: [], durationMs: 30000, spring: nil).window(2)
        #expect(near(w.fromMs, 20000 - SpringMath.settleTime(SpringConfig()) - 2100))
    }

    @Test func followsTheRecordingAcrossChunks() {
        let events = stride(from: 0.0, through: 30000, by: 100).map { MouseEvent(kind: .move, timeMs: $0, position: Vec2($0 / 10, 100)) }
        let moving = plan(events: events, durationMs: 30000, spring: nil)
        // Without smoothing the cursor sits on the last recorded position in every chunk.
        for t in [500.0, 9_950, 10_050, 25_000] {
            let p = moving.position(at: t)
            #expect(p.map { near($0.x, (t / 100).rounded(.down) * 10, 1e-3) } == true, "t = \(t)")
        }
        #expect(plan(events: [], durationMs: 1000).position(at: 0) == nil)
    }
}
