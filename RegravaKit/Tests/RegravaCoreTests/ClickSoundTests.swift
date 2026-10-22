import Foundation
import Testing
@testable import RegravaCore

struct ClickSoundTests {
    func project(_ events: [(MouseEventKind, Double)]) -> Project {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 2, durationMs: 10_000, fps: 60),
                        mouseEvents: events.map { MouseEvent(kind: $0.0, timeMs: $0.1, position: Vec2(0, 0)) })
        p.audio.clickSoundEffect = .appleMagicMouse
        return p
    }

    @Test func shortPressIsOneClickAndLongPressIsDownThenUp() {
        let p = project([(.down, 1000), (.up, 1100), (.down, 2000), (.up, 2600), (.move, 3000), (.down, 4000)])
        let sounds = p.plannedClickSounds
        #expect(sounds.map(\.kind) == [.click, .down, .up])
        #expect(sounds.map(\.playbackTimeMs) == [1000, 2000, 2600])
    }

    @Test func skipsCutsFastPartsAndTimeZero() {
        var p = project([(.down, 0), (.up, 400), (.down, 3000), (.up, 3500), (.down, 6000), (.up, 6500), (.down, 9000)])
        p.slices = [Slice(sourceStartMs: 0, sourceEndMs: 2000), Slice(sourceStartMs: 5000, sourceEndMs: 10_000)]
        p.slices[1].timeScale = 0.25 // 4×
        // Only the up at 400 is left: 0 is at playback time 0, the rest is cut or 4×.
        #expect(p.plannedClickSounds.map(\.kind) == [.up])
        p.slices[1].timeScale = 1
        // 0 is at playback 0; 400 sounds; 3000 is cut; 6000 and 6500 sound.
        #expect(p.plannedClickSounds.map(\.kind) == [.up, .down, .up])
        #expect(p.plannedClickSounds.map(\.playbackTimeMs) == [400, 3000, 3500])
    }

    @Test func offWithoutASet() {
        var p = project([(.down, 1000), (.up, 1100), (.down, 2000)])
        p.audio.clickSoundEffect = nil
        #expect(p.plannedClickSounds.isEmpty)
    }
}
