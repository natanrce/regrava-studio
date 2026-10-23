import Foundation

/// Hover changes found in the recording (`cursorAnalysis.detectHoverChanges`): moments moving the mouse
/// made something under it light up. Stored as `cursor-hover_v3.json` in chunks of session time,
/// `{chunks: [{sessionIndex, startMs, endMs, result}]}`.
public struct CursorHovers: Codable, Hashable, Sendable {
    public struct Chunk: Codable, Hashable, Sendable {
        public var sessionIndex: Int
        public var startMs: Double
        public var endMs: Double
        public var result: [Double]

        public init(sessionIndex: Int = 0, startMs: Double, endMs: Double, result: [Double]) {
            self.sessionIndex = sessionIndex
            self.startMs = startMs
            self.endMs = endMs
            self.result = result
        }
    }

    public static let fileName = "cursor-hover_v3.json"

    public var chunks: [Chunk]

    public init(chunks: [Chunk]) { self.chunks = chunks }

    public static func url(bundle: URL) -> URL { bundle.appendingPathComponent(fileName) }

    public static func load(bundle: URL) -> CursorHovers? {
        (try? Data(contentsOf: url(bundle: bundle))).flatMap { try? JSONDecoder().decode(CursorHovers.self, from: $0) }
    }

    public func save(bundle: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(bundle: bundle), options: .atomic)
    }

    /// Hover times in recording ms, ascending (one session, starting at 0).
    public var timesMs: [Double] { chunks.flatMap(\.result).sorted() }

    /// Whether the chunks cover `0..<durationMs` without gaps.
    public func covers(durationMs: Double) -> Bool {
        var reached = 0.0
        for chunk in chunks.sorted(by: { $0.startMs < $1.startMs }) where chunk.startMs <= reached + 0.5 {
            reached = max(reached, chunk.endMs)
        }
        return reached >= durationMs - 0.5
    }
}

public extension Project {
    /// Hover times feed the cursor only with the toggle on and smooth movement on.
    func cursorHoverTimes(_ hovers: CursorHovers?) -> [Double] {
        guard cursor.followRecordedPositionOnHover, animation.mouseSpring != nil, let hovers else { return [] }
        return hovers.timesMs
    }
}
