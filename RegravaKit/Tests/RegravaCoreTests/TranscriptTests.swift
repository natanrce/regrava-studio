import Foundation
import Testing
@testable import RegravaCore

struct TranscriptTests {
    @Test func timingMatchesTheRegexReplacementForms() {
        func syllables(_ word: String) -> Int {
            var w = word.lowercased()
            if w.count <= 3 { return 1 }
            w = w.replacingOccurrences(of: "(?:[^laeiouy]es|ed|[^laeiouy]e)$", with: "", options: .regularExpression)
            w = w.replacingOccurrences(of: "^y", with: "", options: .regularExpression)
            let matches = (try? NSRegularExpression(pattern: "[aeiouy]{1,2}"))?.numberOfMatches(in: w, range: NSRange(w.startIndex..., in: w)) ?? 0
            return matches > 0 ? matches : 1
        }
        func duration(_ text: String) -> Double {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            var total = 0
            for part in trimmed.split(whereSeparator: \.isWhitespace) {
                let cleaned = String(part).replacingOccurrences(of: "[^A-Za-z0-9_]", with: "", options: .regularExpression)
                if !cleaned.isEmpty { total += syllables(cleaned) }
            }
            return Double(total) / 3 * 1000
        }
        let samples = ["", "  ", "the", "recording", "Studio", "played", "yes", "Yesterday", "boxes", "make", "table",
                       "café", "cafe\u{301}s", "naïve", "über", "日本語", "emoji😀word", "snake_case", "R2-D2!", "don't",
                       " hello world ", "line\nbreak", "YYY", "eye", "queue", "rhythm", "ﬁne", "İstanbul", "x̧yz"]
        for text in samples {
            #expect(TranscriptTiming.estimatedDurationMs(text) == duration(text), "\(text)")
            #expect(TranscriptTiming.syllables(text) == syllables(text), "\(text)")
        }
    }

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

struct CaptionWordsTests {
    @Test func keepsWordsInsideClipsAndExportsSRT() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 640, height: 360), pointPixelScale: 1, durationMs: 10_000, fps: 30), mouseEvents: [])
        project.splitSlice(at: 2000)
        project.splitSlice(at: 4000)
        project.removeSlice(project.slices[1].id)
        let words = [
            TranscriptWord(index: 0, startMs: 500, endMs: 900, text: "Hello"),
            TranscriptWord(index: 1, startMs: 2500, endMs: 3000, text: " cut"),
            TranscriptWord(index: 2, startMs: 4500, endMs: 5000, text: " world"),
            TranscriptWord(index: 3, startMs: 6000, endMs: 6500, text: " [clacking]", type: "sound-label"),
            TranscriptWord(index: 4, startMs: 7000, endMs: 7200, text: " hidden", isHidden: true),
        ]
        let visible = CaptionWords.visible(words, resolver: project.resolver, showSoundLabels: false)
        #expect(visible.map(\.index) == [0, 2])
        #expect(CaptionWords.visible(words, resolver: project.resolver, showSoundLabels: true).map(\.index) == [0, 2, 3])
        let srt = CaptionWords.srt(visible, resolver: project.resolver)
        #expect(srt == "1\n00:00:00,500 --> 00:00:00,900\nHello\n\n2\n00:00:02,500 --> 00:00:03,000\nworld\n")
    }
}
