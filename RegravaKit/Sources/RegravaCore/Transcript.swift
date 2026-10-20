import Foundation

// Transcripts: one per microphone session, words in the session file's time, stored
// beside project.json, outside the project config.

/// A transcribed word (`TranscriptWord`). The first word has no leading space, every other
/// word is stored as " word".
public struct TranscriptWord: Codable, Hashable, Sendable {
    public var index: Int
    public var startMs: Double
    public var endMs: Double
    public var text: String
    /// "Cut from transcript only": hidden from captions, video unchanged.
    public var isHidden: Bool?
    /// "sound-label" for audio-event labels like "[keyboard clacking]".
    public var type: String?

    public init(index: Int, startMs: Double, endMs: Double, text: String, isHidden: Bool? = nil, type: String? = nil) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.isHidden = isHidden
        self.type = type
    }
}

/// How a transcript was made. Only Apple's speech recognition ("Local") is available here.
public struct TranscriptGenerator: Codable, Hashable, Sendable {
    public var type: String
    public var locale: String?

    public init(type: String = "system", locale: String?) {
        self.type = type
        self.locale = locale
    }

    public static func system(locale: String) -> TranscriptGenerator { TranscriptGenerator(type: "system", locale: locale) }
}

/// `transcripts/microphone-session-<i>.json`: `{generator, transcript}`.
public struct SessionTranscript: Codable, Hashable, Sendable {
    public var generator: TranscriptGenerator
    public var transcript: [TranscriptWord]

    public init(generator: TranscriptGenerator, transcript: [TranscriptWord]) {
        self.generator = generator
        self.transcript = transcript
    }

    public static func url(bundle: URL, sessionIndex: Int = 0) -> URL {
        bundle.appendingPathComponent("transcripts", isDirectory: true).appendingPathComponent("microphone-session-\(sessionIndex).json")
    }

    public static func load(bundle: URL, sessionIndex: Int = 0) -> SessionTranscript? {
        guard let data = try? Data(contentsOf: url(bundle: bundle, sessionIndex: sessionIndex)) else { return nil }
        return try? JSONDecoder().decode(SessionTranscript.self, from: data)
    }

    public func save(bundle: URL, sessionIndex: Int = 0) throws {
        let url = Self.url(bundle: bundle, sessionIndex: sessionIndex)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Trimmed text, leading space on all but the first word, indices rewritten to 0…n−1.
    public static func normalized(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words.enumerated().map { i, w in
            var word = w
            let trimmed = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            word.text = i == 0 ? trimmed : " " + trimmed
            word.index = i
            return word
        }
    }
}

public enum TranscriptTiming {
    /// Spoken syllables per second.
    static let syllablesPerSecond = 3.0

    /// Syllables of one word.
    static func syllables(_ word: String) -> Int {
        var w = word.lowercased()
        if w.count <= 3 { return 1 }
        w = w.replacingOccurrences(of: "(?:[^laeiouy]es|ed|[^laeiouy]e)$", with: "", options: .regularExpression)
        w = w.replacingOccurrences(of: "^y", with: "", options: .regularExpression)
        let matches = (try? NSRegularExpression(pattern: "[aeiouy]{1,2}"))?.numberOfMatches(in: w, range: NSRange(w.startIndex..., in: w)) ?? 0
        return matches > 0 ? matches : 1
    }

    /// Estimated spoken duration in ms. Only ASCII letters, digits and `_` count as word
    /// characters, so a word of only non-ASCII letters counts as zero.
    static func estimatedDurationMs(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var total = 0
        for part in trimmed.split(whereSeparator: \.isWhitespace) {
            let cleaned = String(part).replacingOccurrences(of: "[^A-Za-z0-9_]", with: "", options: .regularExpression)
            if !cleaned.isEmpty { total += syllables(cleaned) }
        }
        return Double(total) / syllablesPerSecond * 1000
    }

    /// A word much longer than it takes to say starts later.
    public static func onsetMs(_ word: TranscriptWord) -> Double {
        let duration = word.endMs - word.startMs
        let estimate = estimatedDurationMs(word.text)
        return duration <= estimate * 2 ? word.startMs : word.endMs - estimate
    }

    /// The words in source time with estimated onsets.
    public static func clientTranscript(_ sessions: [(sessionStartMs: Double, words: [TranscriptWord])]) -> [TranscriptWord] {
        sessions.flatMap { session in
            session.words.map { w in
                var word = w
                word.startMs += session.sessionStartMs
                word.endMs += session.sessionStartMs
                word.startMs = onsetMs(word)
                return word
            }
        }
    }
}

public enum CaptionWords {
    /// `visibleCaptionWords`: not hidden, sound labels only when shown, and at least partly
    /// inside a clip.
    public static func visible(_ transcript: [TranscriptWord], resolver: TimeResolver, showSoundLabels: Bool) -> [TranscriptWord] {
        transcript.filter { w in
            w.isHidden != true
                && !(!showSoundLabels && w.type == "sound-label")
                && resolver.isSourceRangePresent(w.startMs, w.endMs)
        }
    }

    /// "Export transcript": one SRT cue per word in playback time, 1-based.
    public static func srt(_ words: [TranscriptWord], resolver: TimeResolver) -> String {
        func stamp(_ ms: Double) -> String {
            let total = Int(max(ms, 0).rounded())
            return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
        }
        return words.enumerated().map { i, w in
            "\(i + 1)\n\(stamp(resolver.sourceToPlayback(w.startMs))) --> \(stamp(resolver.sourceToPlayback(w.endMs)))\n\(w.text.trimmingCharacters(in: .whitespaces))\n"
        }.joined(separator: "\n")
    }
}
