import Foundation

// "Hide during silence": the camera hides during long quiet stretches of the microphone.

public struct SilenceChunk: Codable, Hashable, Sendable {
    public var startMs: Double
    public var endMs: Double

    public init(startMs: Double, endMs: Double) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// The quiet stretches found for one minimum duration, stored as `silence_v1.json`.
public struct CameraSilence: Codable, Hashable, Sendable {
    public static let fileName = "silence_v1.json"

    public var minSilenceDurationMs: Double
    public var chunks: [SilenceChunk]

    public init(minSilenceDurationMs: Double, chunks: [SilenceChunk]) {
        self.minSilenceDurationMs = minSilenceDurationMs
        self.chunks = chunks
    }

    public static func load(bundle: URL) -> CameraSilence? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(CameraSilence.self, from: data)
    }

    public func save(bundle: URL) throws {
        try JSONEncoder().encode(self).write(to: bundle.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

public enum SilenceDetection {
    /// `project.silenceChunks` options.
    public static let thresholdRatio01 = 0.1
    public static let windowSizeMs = 50.0
    /// The camera stays until 500 ms into a silence and is back 500 ms before its end.
    static let edgeMs = 500.0

    /// `minSilenceDuration`: the setting rounded to 100 ms.
    public static func minimumDurationMs(_ hideDuringSilenceMs: Double) -> Double {
        (hideDuringSilenceMs / 100).rounded() * 100
    }

    /// `detectSilence`: `windowSizeMs` windows whose RMS is under `thresholdRatio01` × the
    /// loudest window's, joined, kept when at least `minSilenceDurationMs` long. File time.
    public static func chunks(windowRMS: [Double], durationMs: Double, windowSizeMs: Double = windowSizeMs,
                              thresholdRatio01: Double = thresholdRatio01, minSilenceDurationMs: Double) -> [SilenceChunk] {
        guard let loudest = windowRMS.max(), loudest > 0 else {
            return durationMs >= minSilenceDurationMs ? [SilenceChunk(startMs: 0, endMs: durationMs)] : []
        }
        let limit = thresholdRatio01 * loudest
        var out: [SilenceChunk] = []
        var start: Int?
        func close(_ end: Int) {
            guard let s = start else { return }
            let chunk = SilenceChunk(startMs: Double(s) * windowSizeMs, endMs: min(Double(end) * windowSizeMs, durationMs))
            if chunk.endMs - chunk.startMs >= minSilenceDurationMs { out.append(chunk) }
            start = nil
        }
        for (i, rms) in windowRMS.enumerated() {
            if rms < limit {
                if start == nil { start = i }
            } else {
                close(i)
            }
        }
        close(windowRMS.count)
        return out
    }

    /// Inside a long enough silence, away from its edges.
    public static func isSilent(_ chunks: [SilenceChunk], at t: Double, hideDuringSilenceMs: Double) -> Bool {
        // Chunks are ordered and apart: the first ending at or after `t` is the only candidate.
        guard let i = ceilSearch(count: chunks.count, value: t, key: { chunks[$0].endMs }), chunks[i].startMs <= t else { return false }
        let chunk = chunks[i]
        guard chunk.endMs - chunk.startMs >= hideDuringSilenceMs else { return false }
        return t - chunk.startMs >= edgeMs && chunk.endMs - t >= edgeMs
    }
}
