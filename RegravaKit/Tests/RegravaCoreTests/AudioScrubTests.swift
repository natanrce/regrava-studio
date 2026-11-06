import XCTest
@testable import RegravaCore

final class AudioScrubTests: XCTestCase {
    private func motion(_ samples: [(Double, Double)]) -> ScrubMotion {
        var m = ScrubMotion()
        for (t, h) in samples { m.add(timeMs: t, hostMs: h) }
        return m
    }

    func testGestureStartsAfterAQuarterSecondRest() {
        var m = ScrubMotion()
        XCTAssertTrue(m.add(timeMs: 0, hostMs: 0))
        XCTAssertFalse(m.add(timeMs: 10, hostMs: 250))
        XCTAssertTrue(m.add(timeMs: 20, hostMs: 500.1))
        XCTAssertEqual(m.samples.count, 1)
    }

    func testKeepsEightSamples() {
        let m = motion((0..<12).map { (Double($0), Double($0) * 10) })
        XCTAssertEqual(m.samples.count, 8)
        XCTAssertEqual(m.samples.first?.timeMs, 4)
    }

    func testTypicalGapIsTheClampedMedian() {
        XCTAssertEqual(motion([(0, 0)]).typicalGapMs, 16)
        XCTAssertEqual(motion([(0, 0), (1, 10), (2, 20), (3, 50)]).typicalGapMs, 10)
        XCTAssertEqual(motion([(0, 0), (1, 1), (2, 2)]).typicalGapMs, 4)
        XCTAssertEqual(motion([(0, 0), (1, 200), (2, 400)]).typicalGapMs, 125)
    }

    func testEstimateFitsTheSpeed() throws {
        let m = motion([(0, 0), (10, 10), (20, 20), (30, 30)])
        let now = try XCTUnwrap(m.estimate(atHostMs: 30))
        XCTAssertEqual(now.rate, 1, accuracy: 1e-12)
        XCTAssertTrue(now.isFresh)
        XCTAssertEqual(now.timeMs, 30, accuracy: 1e-12)
        let ahead = try XCTUnwrap(m.estimate(atHostMs: 35))
        XCTAssertEqual(ahead.timeMs, 35, accuracy: 1e-12)
    }

    func testEstimateDecaysOnceStale() throws {
        let m = motion([(0, 0), (10, 10), (20, 20), (30, 30)])
        // Fresh for max(10 × 2.5, 40) ms, then e^(−(age − 40) / 30).
        let e = try XCTUnwrap(m.estimate(atHostMs: 80))
        XCTAssertFalse(e.isFresh)
        XCTAssertEqual(e.rate, exp(-10.0 / 30), accuracy: 1e-12)
        XCTAssertEqual(e.timeMs, 30 + exp(-10.0 / 30) * 10, accuracy: 1e-12)
        XCTAssertNil(ScrubMotion().estimate(atHostMs: 0))
    }

    func testRateChasesTheError() {
        let fresh = ScrubMotion.Estimate(timeMs: 0, rate: 1, isFresh: true)
        var r = ScrubRate()
        XCTAssertEqual(r.step(errorMs: 80, motion: fresh, elapsedMs: 25), (1 - exp(-1.0)) * 2, accuracy: 1e-12)
        var clamped = ScrubRate()
        XCTAssertEqual(clamped.step(errorMs: 800, motion: fresh, elapsedMs: 25), (1 - exp(-1.0)) * 4, accuracy: 1e-12)
        var opposing = ScrubRate(rate: 1)
        XCTAssertEqual(opposing.step(errorMs: -200, motion: fresh, elapsedMs: 25), 1 + (1 - exp(-1.0)) * -1, accuracy: 1e-12)
        var stale = ScrubRate(rate: 2)
        XCTAssertEqual(stale.step(errorMs: 80, motion: ScrubMotion.Estimate(timeMs: 0, rate: 1, isFresh: false), elapsedMs: 50), 2 * exp(-2.0), accuracy: 1e-12)
    }

    func testNewGestureStartsASnippet() {
        var control = ScrubControl()
        var started: [(Double, Double, Double)] = []
        control.add(timeMs: 1000, hostMs: 0, head: nil) { started.append(($0, $1, $2)) }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].0, 48_000)
        XCTAssertEqual(started[0].1, 1)
        XCTAssertEqual(started[0].2, 1)
        XCTAssertEqual(control.snippetFramesLeft, 4800)
        let head = ScrubHeadState(direction: 1, positionFrames: 48_000)
        // Still: the snippet plays at full gain for 100 ms, then stops.
        var decision = control.decide(hostMs: 1, elapsedMs: 256.0 / 48, head: { head }) { _, _, _ in XCTFail() }
        XCTAssertEqual(decision.rate, 1)
        XCTAssertEqual(decision.gain, 1)
        XCTAssertEqual(control.snippetFramesLeft, 4800 - 256)
        for _ in 0..<18 { decision = control.decide(hostMs: 1, elapsedMs: 256.0 / 48, head: { head }) { _, _, _ in } }
        XCTAssertEqual(decision.gain, 0)
    }

    func testJumpRestartsTheVoice() {
        var control = ScrubControl()
        control.add(timeMs: 0, hostMs: 0, head: nil) { _, _, _ in }
        var started: [(Double, Double, Double)] = []
        control.add(timeMs: 1000, hostMs: 10, head: ScrubHeadState(direction: -1, positionFrames: 0)) { started.append(($0, $1, $2)) }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].0, 48_000)
        XCTAssertEqual(started[0].1, -1)
        XCTAssertEqual(started[0].2, 1)
        control.add(timeMs: 1100, hostMs: 20, head: ScrubHeadState(direction: 1, positionFrames: 48_000)) { _, _, _ in XCTFail() }
    }

    func testGainSmoothstepsWithSpeed() {
        var control = ScrubControl()
        for i in 0..<5 { control.add(timeMs: Double(i) * 10, hostMs: Double(i) * 10, head: nil) { _, _, _ in } }
        control.snippetFramesLeft = 0
        control.rate.rate = 0.06
        let head = ScrubHeadState(direction: 1, positionFrames: MixFormat.sampleRate * 0.040)
        let decision = control.decide(hostMs: 40, elapsedMs: 0, head: { head }) { _, _, _ in XCTFail() }
        XCTAssertEqual(decision.rate, 0.06)
        XCTAssertEqual(decision.gain, 0.5, accuracy: 1e-12)
    }

    func testVoiceGainsCrossfade() {
        XCTAssertEqual(PreviewGainRamp.stepVoice(1, isNewest: false), 1 - 1 / Float(960))
        XCTAssertEqual(PreviewGainRamp.stepVoice(0, isNewest: true), 1 / Float(960))
        XCTAssertEqual(PreviewGainRamp.stepVoice(1, isNewest: true), 1)
        XCTAssertEqual(PreviewGainRamp.stepVoice(0, isNewest: false), 0)
        var gain: Float = 0
        for _ in 0..<480 { gain = PreviewGainRamp.stepMaster(gain, fadingOut: false) }
        XCTAssertEqual(gain, 1, accuracy: 1e-4)
        var out: Float = 1
        for _ in 0..<1920 { out = PreviewGainRamp.stepMaster(out, fadingOut: true) }
        XCTAssertEqual(out, 0.5, accuracy: 1e-3)
        XCTAssertEqual(PreviewGainRamp.outputScale(master: 1, voiceGainSum: 0.5), 2)
        XCTAssertEqual(PreviewGainRamp.outputScale(master: 0, voiceGainSum: 0), 0)
    }
}
