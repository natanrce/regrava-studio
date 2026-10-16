import Testing
@testable import RegravaCore

@Suite struct TypingTests {
    private func keys(from start: Double, count: Int, every: Double) -> [Keystroke] {
        (0..<count).flatMap { i -> [Keystroke] in
            let t = start + Double(i) * every
            return [Keystroke(kind: .down, timeMs: t), Keystroke(kind: .up, timeMs: t + 40)]
        }
    }

    @Test func typingNeedsThreePressesAndNoMouseAfter() {
        let strokes = keys(from: 1000, count: 5, every: 200)
        let still = [MouseEvent(kind: .move, timeMs: 0, position: Vec2(0, 0))]
        #expect(!Typing.isActivelyTyping(at: 1300, keystrokes: strokes, mouseEvents: still))
        #expect(Typing.isActivelyTyping(at: 1500, keystrokes: strokes, mouseEvents: still))
        #expect(!Typing.isActivelyTyping(at: 4000, keystrokes: strokes, mouseEvents: still))
        let moved = still + [MouseEvent(kind: .move, timeMs: 1450, position: Vec2(5, 5))]
        #expect(!Typing.isActivelyTyping(at: 1460, keystrokes: strokes, mouseEvents: moved))
    }

    @Test func cursorFadesWhileTyping() {
        let project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 5000, fps: 60),
            mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(10, 10))],
            keystrokes: keys(from: 1000, count: 10, every: 150)
        )
        let track = CameraTrack(project: project)
        #expect(track.frame(at: 900).cursorOpacity == 1)
        #expect(track.frame(at: 1800).cursorOpacity < 0.05)
        // 1.8 s after the last key the cursor comes back.
        #expect(track.frame(at: 4900).cursorOpacity > 0.9)
    }

    @Test func suggestsLongFastRuns() {
        let fast = keys(from: 1000, count: 12, every: 180)   // ~2 s, ~11 strokes/s
        let short = keys(from: 6000, count: 3, every: 100)   // too short
        let ranges = Typing.suggestions((fast + short).sorted { $0.timeMs < $1.timeMs })
        #expect(ranges == [TimeRange(startMs: 1000, endMs: 1000 + 11 * 180 + 40)])
    }
}
