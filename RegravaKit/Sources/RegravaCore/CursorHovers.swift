import Foundation

/// Hover changes found in the recording (`cursorAnalysis.detectHoverChanges`): moments moving the mouse
/// made something under it light up. Stored as `cursor-hover_v3.json` in chunks of session time,
/// `{chunks: [{sessionIndex, startMs, endMs, result}]}`.
///
/// The detection reads each session in 20 s stretches. Every finished stretch is kept on its own
/// in `cache/cursor-hover_v3/` (`{"json": [times]}`), so an interrupted detection resumes where it
/// stopped, and the whole set is written once every stretch is done.
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

        public var stretch: Stretch { Stretch(sessionIndex: sessionIndex, startMs: startMs, endMs: endMs) }
    }

    /// A stretch of one session's time, `startMs..<endMs`.
    public struct Stretch: Hashable, Sendable {
        public var sessionIndex: Int
        public var startMs: Double
        public var endMs: Double

        public init(sessionIndex: Int = 0, startMs: Double, endMs: Double) {
            self.sessionIndex = sessionIndex
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public static let fileName = "cursor-hover_v3.json"
    /// Where finished stretches are kept, inside the project's `cache` folder.
    public static let stretchesDirectoryName = "cursor-hover_v3"
    /// Length of a stretch.
    public static let stretchDurationMs = 20_000.0
    /// The last stretch of a session ends here (`Number.MAX_SAFE_INTEGER`): it reads to the end.
    public static let openEndMs = 9_007_199_254_740_991.0
    /// Stretches read at once.
    public static let concurrentStretches = 2
    /// How much more a stretch behind the demanded moment counts than one as far ahead of it.
    public static let behindDemandWeight = 2.0

    public var chunks: [Chunk]

    public init(chunks: [Chunk]) { self.chunks = chunks }

    public static func url(bundle: URL) -> URL { bundle.appendingPathComponent(fileName) }

    /// The complete result, else the stretches finished so far (nil when there are none).
    public static func load(bundle: URL) -> CursorHovers? {
        if let complete = (try? Data(contentsOf: url(bundle: bundle))).flatMap({ try? JSONDecoder().decode(CursorHovers.self, from: $0) }) {
            return complete
        }
        let stored = storedChunks(bundle: bundle)
        return stored.isEmpty ? nil : CursorHovers(chunks: stored)
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

    // MARK: Stretches

    /// A session's stretches: every 20 s from its start, the last one open-ended.
    public static func stretches(durationMs: Double, sessionIndex: Int = 0) -> [Stretch] {
        var result: [Stretch] = []
        var start = 0.0
        repeat {
            let end = start + stretchDurationMs
            result.append(Stretch(sessionIndex: sessionIndex, startMs: start, endMs: end >= durationMs ? openEndMs : end))
            start = end
        } while start < durationMs
        return result
    }

    /// The order stretches are read in: nearest the demanded moment first, a stretch behind it
    /// counting twice its distance; ties (and no demand) keep session order.
    public static func scheduled(_ stretches: [Stretch], demandMs: Double?) -> [Stretch] {
        guard let demandMs else { return stretches }
        return stretches.enumerated().sorted { a, b in
            let da = distance(a.element, demandMs), db = distance(b.element, demandMs)
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
    }

    static func distance(_ stretch: Stretch, _ demandMs: Double) -> Double {
        if demandMs < stretch.startMs { return stretch.startMs - demandMs }
        if demandMs > stretch.endMs { return (demandMs - stretch.endMs) * behindDemandWeight }
        return 0
    }

    // MARK: Stored stretches

    public static func stretchesDirectory(bundle: URL) -> URL {
        bundle.appendingPathComponent("cache", isDirectory: true).appendingPathComponent(stretchesDirectoryName, isDirectory: true)
    }

    public static func stretchURL(bundle: URL, _ stretch: Stretch) -> URL {
        stretchesDirectory(bundle: bundle).appendingPathComponent("\(stretch.sessionIndex)-\(Int64(stretch.startMs))-\(Int64(stretch.endMs)).json")
    }

    private struct StoredStretch: Codable {
        var json: [Double]
    }

    /// The hover times of a finished stretch, nil when it has not been read.
    public static func loadStretch(bundle: URL, _ stretch: Stretch) -> [Double]? {
        (try? Data(contentsOf: stretchURL(bundle: bundle, stretch))).flatMap { try? JSONDecoder().decode(StoredStretch.self, from: $0).json }
    }

    public static func saveStretch(_ result: [Double], bundle: URL, _ stretch: Stretch) throws {
        try FileManager.default.createDirectory(at: stretchesDirectory(bundle: bundle), withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredStretch(json: result)).write(to: stretchURL(bundle: bundle, stretch), options: .atomic)
    }

    /// Every finished stretch kept in the project, in session order.
    public static func storedChunks(bundle: URL) -> [Chunk] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stretchesDirectory(bundle: bundle).path)) ?? []
        return names.compactMap { name -> Chunk? in
            guard name.hasSuffix(".json") else { return nil }
            let parts = name.dropLast(5).split(separator: "-")
            guard parts.count == 3, let session = Int(parts[0]), let start = Int64(parts[1]), let end = Int64(parts[2]) else { return nil }
            let stretch = Stretch(sessionIndex: session, startMs: Double(start), endMs: Double(end))
            return loadStretch(bundle: bundle, stretch).map { Chunk(sessionIndex: session, startMs: stretch.startMs, endMs: stretch.endMs, result: $0) }
        }.sorted { ($0.sessionIndex, $0.startMs) < ($1.sessionIndex, $1.startMs) }
    }
}

public extension Project {
    /// Hover times feed the cursor only with the toggle on and smooth movement on.
    func cursorHoverTimes(_ hovers: CursorHovers?) -> [Double] {
        guard cursor.followRecordedPositionOnHover, animation.mouseSpring != nil, let hovers else { return [] }
        return hovers.timesMs
    }
}
