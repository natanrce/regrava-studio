import Foundation
import Testing
@testable import RegravaCore

struct TranscriptEditingTests {
    func project(_ ms: Double = 20_000) -> Project {
        Project(recording: RecordingInfo(videoSize: Size2(width: 640, height: 360), pointPixelScale: 1, durationMs: ms, fps: 30), mouseEvents: [])
    }

    // Short words so the onset estimate keeps their start (1 syllable = 333 ms).
    let words = [
        TranscriptWord(index: 0, startMs: 1000, endMs: 1200, text: "So"),
        TranscriptWord(index: 1, startMs: 1300, endMs: 1500, text: " um"),
        TranscriptWord(index: 2, startMs: 1600, endMs: 1800, text: " this."),
        TranscriptWord(index: 3, startMs: 4000, endMs: 4200, text: " Yes"),
        TranscriptWord(index: 4, startMs: 4230, endMs: 4400, text: " no"),
    ]

    @Test func tokensInsertPausesAndMarkFillers() {
        let t = TranscriptEditing.tokens(words, locale: "en_US")
        #expect(t.map(\.kind) == [.word, .word, .word, .gap, .word, .word])
        #expect(t[3].sourceStartMs == 1800 && t[3].sourceEndMs == 4000)
        #expect(t[1].fillerTier == 1 && t[0].fillerTier == 2 && t[2].fillerTier == nil)
        #expect(TranscriptEditing.paragraphs(t).count == 2)
    }

    @Test func deletingAFillerTakesThePausesAround() {
        var p = project()
        let t = TranscriptEditing.tokens(words, locale: "en")
        // "um" alone: from previous kept end + 30 to next kept start − 30.
        #expect(TranscriptEditing.delete([t[1]], tokens: t, project: &p) == .removed(340))
        #expect(p.slices.map { [$0.sourceStartMs, $0.sourceEndMs] } == [[0, 1230], [1570, 20_000]])
    }

    @Test func deletingAWordKeeps40msOfAirAndSplitsCloseGaps() {
        var p = project()
        let t = TranscriptEditing.tokens(words, locale: "en")
        // "Yes": previous kept word is far (gap token between), next kept "no" is 30 ms away → midpoint.
        _ = TranscriptEditing.delete([t[4]], tokens: t, project: &p)
        #expect(p.slices.map { [$0.sourceStartMs, $0.sourceEndMs] } == [[0, 3960], [4215, 20_000]])
    }

    @Test func tighteningAPauseKeeps100msEachSide() {
        var p = project()
        let t = TranscriptEditing.tokens(words, locale: "en")
        _ = TranscriptEditing.delete([t[3]], tokens: t, project: &p)
        #expect(p.slices.map { [$0.sourceStartMs, $0.sourceEndMs] } == [[0, 1900], [3900, 20_000]])
        #expect(!TranscriptEditing.canTighten(TranscriptEditing.tokens(words, locale: "en")[3], in: p))
    }

    @Test func refusesToDeleteEverythingAndRestoresWords() {
        var p = project(2000)
        let t = TranscriptEditing.tokens([TranscriptWord(index: 0, startMs: 0, endMs: 2000, text: "Hi")], locale: "en")
        #expect(TranscriptEditing.delete(t, tokens: t, project: &p) == .wouldRemoveAll)
        var q = project()
        let all = TranscriptEditing.tokens(words, locale: "en")
        _ = TranscriptEditing.delete([all[2]], tokens: all, project: &q)
        TranscriptEditing.restore([all[2]], project: &q)
        #expect(q.slices.count == 1 || q.resolver.isSourceRangePresent(1600, 1800))
        #expect(TranscriptEditing.isPresent(all[2], in: q))
    }

    @Test func correctionSharesTimeByLength() {
        let fixed = TranscriptEditing.correct(words, from: 0, to: 1, text: "Sooo okay")
        #expect(fixed.map(\.text).prefix(3) == ["Sooo", " okay", " this."])
        #expect(fixed[0].startMs == 1000 && fixed[0].endMs == 1250 && fixed[1].endMs == 1500)
        #expect(TranscriptEditing.setHidden(words, from: 1, to: 2, hidden: true).map { $0.isHidden == true } == [false, true, true, false, false])
    }
}

struct TimelineWordsTests {
    @Test func labelsAreNearbyAndDoNotOverlap() {
        let p = Project(recording: RecordingInfo(videoSize: Size2(width: 640, height: 360), pointPixelScale: 1, durationMs: 20_000, fps: 30), mouseEvents: [])
        let words = (0..<30).map { TranscriptWord(index: $0, startMs: Double($0) * 200, endMs: Double($0) * 200 + 150, text: $0 == 0 ? "w\($0)" : " w\($0)") }
        let labels = TimelineWords.labels(words, resolver: p.resolver, previewMs: 3000, pxPerMs: 0.1)
        #expect(!labels.isEmpty && labels.count < 30)
        for (a, b) in zip(labels, labels.dropFirst()) {
            #expect(b.offset - a.offset >= (TimelineWords.width(a.text) + TimelineWords.width(b.text)) / 2 + 8 - 1e-9)
        }
        #expect(labels.contains { $0.text == "w15" && $0.opacity == 1 })
    }
}
