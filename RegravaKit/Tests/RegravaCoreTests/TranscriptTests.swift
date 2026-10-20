import Foundation
import Testing
@testable import RegravaCore

struct TranscriptTests {
    @Test func syllablesFollowTheHeuristic() {
        #expect(TranscriptTiming.syllables("the") == 1)
        #expect(TranscriptTiming.syllables("recording") == 3)
        #expect(TranscriptTiming.syllables("studio") == 2)
        #expect(TranscriptTiming.syllables("played") == 1)
    }

    @Test func longWordsStartLater() {
        // "recording" ≈ 3 syllables = 1000 ms; a 3 s span starts 1 s before its end.
        let late = TranscriptWord(index: 0, startMs: 0, endMs: 3000, text: "recording")
        #expect(TranscriptTiming.onsetMs(late) == 2000)
        let normal = TranscriptWord(index: 0, startMs: 0, endMs: 1500, text: " recording")
        #expect(TranscriptTiming.onsetMs(normal) == 0)
        // Non-ASCII only: estimate 0, so the start becomes the end (kept quirk).
        #expect(TranscriptTiming.onsetMs(TranscriptWord(index: 0, startMs: 0, endMs: 300, text: "日本")) == 300)
    }

    @Test func normalizesSpacingAndIndices() {
        let words = SessionTranscript.normalized([
            TranscriptWord(index: 5, startMs: 0, endMs: 1, text: " Hello "),
            TranscriptWord(index: 9, startMs: 1, endMs: 2, text: "world"),
        ])
        #expect(words.map(\.text) == ["Hello", " world"] && words.map(\.index) == [0, 1])
    }

    @Test func savesBesideTheProject() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let t = SessionTranscript(generator: .system(locale: "en_US"), transcript: [TranscriptWord(index: 0, startMs: 0, endMs: 100, text: "Hi")])
        try t.save(bundle: bundle)
        #expect(SessionTranscript.load(bundle: bundle) == t)
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("transcripts/microphone-session-0.json").path))
    }
}
