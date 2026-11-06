import Foundation
import Testing
@testable import RegravaCore

/// Lazy emulation: where the springs start, how far frames are kept, and when they start over.
struct CameraMotionTests {
    func project(_ zooms: [ZoomRange] = [ZoomRange(startMs: 1000, endMs: 2500, scale: 2, mode: .manual, manualTarget: Vec2(0.25, 0.75)),
                                         ZoomRange(startMs: 6000, endMs: 9000, scale: 1.6, mode: .manual, manualTarget: Vec2(0.7, 0.3))]) -> Project {
        var events: [MouseEvent] = []
        var t = 0.0
        while t <= 20_000 {
            events.append(MouseEvent(kind: .move, timeMs: t, position: Vec2(960 + 500 * cos(t / 900), 540 + 300 * sin(t / 700))))
            t += 16
        }
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 20_000, fps: 60), mouseEvents: events)
        p.zooms = zooms
        return p
    }

    func track(_ p: Project, reusing previous: CameraTrack? = nil) -> CameraTrack {
        let track = CameraTrack(project: p, reusing: previous)
        track.motion.budgetMs = nil
        return track
    }

    func time(_ frame: Int) -> Double { Double(frame) * 1000 / 60 }

    /// Frames asked for in order from the start are one emulation from the start.
    @Test func framesInOrderAreOneEmulationFromTheStart() {
        let track = track(project())
        let reference = track.motion.emulatedFrames(from: 0, through: 720)
        for i in 0...720 {
            let frame = track.frame(at: time(i))
            #expect(frame.screenRect == reference[i].screenRect)
            #expect(frame.cursorScale == reference[i].cursorScale)
            #expect(frame.backgroundRect == reference[i].backgroundRect)
        }
        #expect(track.motion.resets == 1)
    }

    /// A first request at 2.3 s starts the springs at rest on their targets at 1.3 s, while
    /// the first zoom is still moving in, and emulates 30 frames past it.
    @Test func aFirstRequestStartsOneSecondBefore() {
        let track = track(project())
        let frame = track.frame(at: time(138))
        #expect(track.motion.resets == 1)
        #expect(track.motion.window.range == 78..<169)
        let lazy = track.motion.emulatedFrames(from: 78, through: 138)
        #expect(frame.screenRect == lazy[60].screenRect)
        // An emulation from the start is still moving into the zoom at 1.3 s and after; the
        // restart sits on the zoom's rectangle from there. Both have settled by 2.3 s.
        let full = track.motion.emulatedFrames(from: 0, through: 138)
        #expect(full[78].screenRect != lazy[0].screenRect)
        #expect(full[88].screenRect != lazy[10].screenRect)
        #expect(full[138].screenRect == frame.screenRect)
    }

    /// The first frame of a restart is the targets at rest: the zoom's rectangle.
    @Test func aRestartSitsOnItsTargets() {
        let p = project()
        let track = track(p)
        let frame = track.frame(at: time(150)) // restart at frame 90 (1.5 s), inside the first zoom
        let start = track.motion.emulatedFrames(from: 90, through: 90)[0]
        #expect(track.motion.window[90]?.screenRect == start.screenRect)
        #expect(frame.screenRect.width > track.layout.restScreen.width)
    }

    /// Within 1 s after the springs, they continue; further on, or before the held frames,
    /// they start over 1 s before the time asked for.
    @Test func continuesWithinOneSecondAndRestartsOtherwise() {
        let track = track(project())
        _ = track.frame(at: time(300))
        #expect(track.motion.springFrame == 330)
        // 390 is 60 frames (1 s) after 330: continued.
        let continued = track.frame(at: time(390))
        #expect(track.motion.resets == 1)
        #expect(continued.screenRect == track.motion.emulatedFrames(from: 240, through: 390)[150].screenRect)
        #expect(track.motion.springFrame == 420)
        // 481 is past 420 + 60: started over at 421.
        _ = track.frame(at: time(481))
        #expect(track.motion.resets == 2)
        #expect(track.motion.window.range.lowerBound == 421)
        // Back before the held frames: started over at 300.
        _ = track.frame(at: time(360))
        #expect(track.motion.resets == 3)
        #expect(track.motion.window.range.lowerBound == 300)
    }

    /// A held frame is answered as held, wherever the springs are.
    @Test func heldFramesAreNotEmulatedAgain() {
        let track = track(project())
        _ = track.frame(at: time(300))
        let runs = track.motion.emulationRuns
        _ = track.frame(at: time(250))
        _ = track.frame(at: time(325))
        #expect(track.motion.emulationRuns == runs)
        #expect(track.motion.resets == 1)
    }

    /// Frames more than 2 s (120 frames) before the last time asked for are dropped.
    @Test func dropsFramesTwoSecondsBehind() {
        let track = track(project())
        for i in 0...600 { _ = track.frame(at: time(i)) }
        #expect(track.motion.window.range.lowerBound == 600 - 120)
        #expect(track.motion.window.range.upperBound <= 600 + 31)
        #expect(track.motion.resets == 1)
    }

    /// A fractional time asks for the frames on both sides; a whole frame only for itself.
    @Test func betweenFramesInterpolates() {
        let track = track(project())
        let a = track.frame(at: time(70))
        let b = track.frame(at: time(71))
        let mid = track.frame(at: (time(70) + time(71)) / 2)
        #expect(abs(mid.screenRect.x - (a.screenRect.x + b.screenRect.x) / 2) < 1e-9)
        #expect(mid.previousScreenRect != nil)
    }

    /// Without an idle scheduler, emulation stops 30 frames past the request; idle steps carry
    /// it to 50 past.
    @Test func idleStepsEmulateFiftyFramesAhead() {
        let track = track(project())
        _ = track.frame(at: time(300))
        #expect(track.hasIdlePrecomputeWork)
        track.stepIdlePrecompute { _ in true }
        #expect(track.motion.springFrame == 350)
        #expect(!track.hasIdlePrecomputeWork)
        // A budget that runs out stops the step.
        _ = track.frame(at: time(310))
        var granted = 5
        track.stepIdlePrecompute { _ in granted -= 1; return granted >= 0 }
        #expect(track.motion.springFrame == 355)
    }

    /// After 512 emulation runs an idle step starts the springs over 1 s before the last
    /// time asked for.
    @Test func manyRunsStartOverInIdleTime() {
        let track = track(project())
        // Every other frame, jumping backward, forces an emulation run without a restart.
        _ = track.frame(at: time(100))
        for _ in 0..<520 {
            track.motion.lock.lock()
            track.motion.trackRequest(time(track.motion.springFrame + 1))
            _ = track.motion.style(frame: track.motion.springFrame + 1)
            track.motion.lock.unlock()
        }
        #expect(track.motion.emulationRuns >= 512)
        let resets = track.motion.resets
        let last = track.motion.lastRequestedFrame
        track.stepIdlePrecompute { _ in false }
        #expect(track.motion.resets == resets + 1)
        #expect(track.motion.window.range.lowerBound == last - 60)
    }

    /// An edit the animation does not read keeps the springs and held frames; any other
    /// starts them over.
    @Test func editsInvalidateOnlyWhatTheAnimationReads() {
        var p = project()
        let first = track(p)
        _ = first.frame(at: time(300))
        p.captions.sizeRatio = 0.08
        p.audio.volume = 0.3
        let kept = track(p, reusing: first)
        #expect(kept.motion === first.motion)
        _ = kept.frame(at: time(310))
        #expect(kept.motion.resets == 1)

        p.zooms[1].scale = 2.4
        let rebuilt = track(p, reusing: kept)
        #expect(rebuilt.motion !== kept.motion)
        _ = rebuilt.frame(at: time(310))
        #expect(rebuilt.motion.resets == 1)
        #expect(rebuilt.motion.window.range.lowerBound == 250)
    }
}
