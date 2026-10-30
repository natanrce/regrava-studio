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

    @Test func lineLengthCountsUTF16Units() {
        // Each emoji is one character but two UTF-16 units: 20 of them fill 40 of the 42.
        let emoji = word(String(repeating: "\u{1F600}", count: 20), 0, 100)
        let lines = CaptionLayout.lines([emoji, word(" abc", 100, 200)], maxWidth: 10_000, measure: measure)
        #expect(lines.map { $0.words.map(\.text) } == [[emoji.text], ["abc"]])
        let ascii = word(String(repeating: "x", count: 20), 0, 100)
        #expect(CaptionLayout.lines([ascii, word(" abc", 100, 200)], maxWidth: 10_000, measure: measure).count == 1)
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

    @Test func influencingLinesMatchAFullScan() {
        // Lines of varied length and spacing, two sharing an edge, one starting a long gap.
        var words: [TranscriptWord] = []
        var t = 0.0
        for i in 0..<120 {
            let gap = [0.0, 1500, 300, 2600, 0, 50][i % 6]
            t += gap
            let length = Double(80 + (i * 37) % 400)
            words.append(word(" w\(i)", t, t + length))
            t += length
        }
        let stage = Rect2(x: 0, y: 0, width: 1920, height: 1080)
        let lines = CaptionLayout.lines(words, maxWidth: 400, measure: measure)
        #expect(lines.count > 10)
        let track = CaptionTrack(lines: lines, config: CaptionsConfig(), stage: stage, resolver: TimeResolver(slices: []), fps: 60)
        func fullScan(_ t: Double) -> [Int] {
            lines.indices.filter { t >= lines[$0].startMs - CaptionTrack.influenceMs && t <= lines[$0].endMs + CaptionTrack.influenceMs }
        }
        var probes = [-5000.0, lines[0].startMs - 1000, lines.last!.endMs + 1000, lines.last!.endMs + 1000.5, t + 10_000]
        for line in lines { probes += [line.startMs - 1000, line.startMs, line.endMs, line.endMs + 1000, line.endMs + 1000.01] }
        for t in stride(from: -2000.0, through: t + 2000, by: 7.3) { probes.append(t) }
        for t in probes { #expect(track.influencingLines(at: t) == fullScan(t)) }

        // Lines out of order still give the same lines as a full scan.
        let shuffled = Array(lines.reversed())
        let unsorted = CaptionTrack(lines: shuffled, config: CaptionsConfig(), stage: stage, resolver: TimeResolver(slices: []), fps: 60)
        for t in probes.prefix(50) {
            #expect(unsorted.influencingLines(at: t) == shuffled.indices.filter { t >= shuffled[$0].startMs - 1000 && t <= shuffled[$0].endMs + 1000 })
        }
        let empty = CaptionTrack(lines: [], config: CaptionsConfig(), stage: stage, resolver: TimeResolver(slices: []), fps: 60)
        #expect(empty.influencingLines(at: 0).isEmpty)
    }
}
