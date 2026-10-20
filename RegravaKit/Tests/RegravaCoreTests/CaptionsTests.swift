import Foundation
import Testing
@testable import RegravaCore

struct CaptionsTests {
    /// 10 px per character plus the 2 px padding on each side.
    func measure(_ text: String) -> Size2 { Size2(width: Double(text.count) * 10 + 4, height: 28) }

    func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord { TranscriptWord(index: 0, startMs: start, endMs: end, text: text) }

    @Test func breaksOnGapsSpansAndLength() {
        let words = [
            word("Hello", 0, 300), word(" there", 300, 600),
            // More than 1 s after the first word's end: new line.
            word(" again", 1400, 1700),
            word(" and", 1700, 1900),
        ]
        let lines = CaptionLayout.lines(words, maxWidth: 10_000, measure: measure)
        #expect(lines.map { $0.words.map(\.text) } == [["Hello", " there"], ["again", " and"]])
        // The end extends by 300 ms but never past the next line's start.
        #expect(lines[0].endMs == 900 && lines[1].endMs == 2200)
    }

    @Test func breaksAt42CharactersAndDropsAnOverlongFirstWord() {
        let long = word(String(repeating: "x", count: 50), 0, 100)
        #expect(CaptionLayout.lines([long, word(" ok", 100, 200)], maxWidth: 10_000, measure: measure).map { $0.words.map(\.text) } == [["ok"]])
        let words = (0..<10).map { word(" word\($0)", Double($0) * 100, Double($0) * 100 + 90) }
        let lines = CaptionLayout.lines(words, maxWidth: 10_000, measure: measure)
        #expect(lines.allSatisfy { $0.words.map(\.text).joined().count <= 42 + 1 })
        #expect(lines.count == 2)
    }

    @Test func lineSizesUseTheSpaceWidth() {
        let line = CaptionLayout.lines([word("Hi", 0, 100), word(" you", 100, 200)], maxWidth: 1000, measure: measure)[0]
        // "Hi" = 24; " you": measure("you") 34 + space 14.
        #expect(line.offsets == [0, 24, 72] && line.maxWordHeight == 28)
    }

    @Test func leftAnchoredBoxGrowsWithSpokenWords() {
        let line = CaptionLayout.lines([word("Hi", 0, 100), word(" you", 500, 800)], maxWidth: 1000, measure: measure)[0]
        let stage = Rect2(x: 0, y: 0, width: 1920, height: 1080)
        let early = CaptionFrame(line: line, config: CaptionsConfig(), stage: stage, t: 50)
        let late = CaptionFrame(line: line, config: CaptionsConfig(), stage: stage, t: 600)
        #expect(early.rect.width == 24 && late.rect.width == 72)
        #expect(early.wordOpacity(1) == 0 && late.wordOpacity(1) == 1)
        // Bottom-centre of the padded stage.
        let padded = stage.padByRatio(-0.1)
        #expect(abs(late.rect.endY - padded.endY) < 1e-9)
    }

    @Test func sceneSettlesOnTheTargets() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 10_000, fps: 60), mouseEvents: [])
        project.style.aspectRatio = 16.0 / 9
        let words = (0..<4).map { word($0 == 0 ? "One" : " word", Double($0) * 1000 + 1000, Double($0) * 1000 + 1500) }
        let lines = CaptionLayout.lines(words, maxWidth: 1500, measure: measure)
        let track = CaptionTrack(lines: lines, config: CaptionsConfig(), stage: Rect2(x: 0, y: 0, width: 1920, height: 1080), resolver: project.resolver, fps: 60)
        let scene = track.scene(atPlayback: 3800)
        #expect(scene.box!.opacity > 0.99)
        #expect(scene.words.count == 4)
        #expect(track.scene(atPlayback: 9000).box!.opacity < 0.01)
    }
}
