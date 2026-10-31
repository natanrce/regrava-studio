import Foundation

/// The drawn cursor, planned in chunks of playback time.
///
/// Each 10 s chunk is planned on its own over the clips that reach into it, widened by the
/// cursor spring's settle time and the planner's lead and approach windows, with times measured
/// from the chunk start. The chunk also carries the events as drawn (at the time the smoothed
/// cursor aims at them), which its motion rotation is computed from.
public final class CursorPlan: @unchecked Sendable {
    public static let chunkMs = 10_000.0
    /// Extra planning on both sides of a chunk: the largest lead plus the approach window.
    public static var marginMs: Double {
        let settings = CursorPathSettings()
        return settings.maxLeadMs + settings.approachWindowMs
    }

    public struct Inputs: Equatable {
        /// `CameraTrack.cursorPathEvents`, in source time.
        public var pathEvents: [MouseEvent]
        /// All events after shake removal, in source time (a Follow heading's history).
        public var cleanedEvents: [MouseEvent]
        public var imageChangesMs: [Double]
        public var hoverTimesMs: [Double]
        public var slices: [Slice]
        public var spring: SpringConfig?
        public var pointPixelScale: Double
        public var rotationMode: CursorRotationMode
        public var rotateOnXMovementRatio: Double
    }

    struct Chunk {
        let playbackStartMs: Double
        let path: SmoothedCursorPath
        let rotation: [CursorRotationKeyframe]
    }

    /// One clip's part inside a chunk's planning window.
    struct Entry {
        var slice: Slice?
        var sourceStartMs: Double
        var sourceEndMs: Double
        /// In chunk time.
        var startMs: Double
        var endMs: Double
        var isAfterCut: Bool
        var link: TimeResolver.Link
        var chunkStartMs: Double

        func toChunk(_ sourceMs: Double) -> Double { link.sourceToPlayback(sourceMs) - chunkStartMs }
    }

    let inputs: Inputs
    let resolver: TimeResolver
    private let lock = NSLock()
    private var chunks: [Int: Chunk?] = [:]
    private var historyKeyframes: [CursorRotationKeyframe]?

    public init(inputs: Inputs) {
        self.inputs = inputs
        resolver = TimeResolver(slices: inputs.slices)
    }

    /// Smoothed cursor position at playback time `t`, in recording pixels.
    public func position(at t: Double) -> Vec2? {
        guard let chunk = chunk(containing: t) else { return nil }
        return chunk.path.position(at: t - chunk.playbackStartMs)
    }

    /// The motion rotation at playback time `t`, before the base rotation.
    public func motionRotation(at t: Double) -> Double {
        guard let chunk = chunk(containing: t) else { return 0 }
        return CursorRotation.rotation(at: t - chunk.playbackStartMs, in: chunk.rotation)
    }

    private func chunk(containing t: Double) -> Chunk? {
        let index = Int((t / Self.chunkMs).rounded(.down))
        lock.lock()
        if let cached = chunks[index] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let made = makeChunk(index)
        lock.lock()
        chunks[index] = made
        lock.unlock()
        return made
    }

    /// Planning window of chunk `index`, in playback time.
    func window(_ index: Int) -> (startMs: Double, fromMs: Double, toMs: Double) {
        let start = Double(index) * Self.chunkMs
        let settle = SpringMath.settleTime(inputs.spring ?? SpringConfig())
        return (start, start - settle - Self.marginMs, start + Self.chunkMs + Self.marginMs)
    }

    /// The clips overlapping `from…to`, clipped to it.
    func entries(from: Double, to: Double, chunkStartMs: Double) -> [Entry] {
        let links = resolver.links
        var result: [Entry] = []
        for (i, link) in links.enumerated() {
            if link.playbackEndMs <= from || link.playbackStartMs >= to { continue }
            let start = max(link.playbackStartMs, from)
            let end = min(link.playbackEndMs, to)
            let previous = i > 0 ? links[i - 1] : nil
            result.append(Entry(
                slice: inputs.slices.indices.contains(i) ? inputs.slices[i] : nil,
                sourceStartMs: link.playbackToSource(start),
                sourceEndMs: link.playbackToSource(end),
                startMs: start - chunkStartMs,
                endMs: end - chunkStartMs,
                isAfterCut: previous.map { $0.sourceEndMs != link.sourceStartMs } == true && start == link.playbackStartMs,
                link: link,
                chunkStartMs: chunkStartMs
            ))
        }
        return result
    }

    private func makeChunk(_ index: Int) -> Chunk? {
        let events = inputs.pathEvents
        guard !events.isEmpty else { return nil }
        let (chunkStart, from, to) = window(index)
        let entries = entries(from: from, to: to, chunkStartMs: chunkStart)

        // Where the cursor is at each clip's start, then every event inside the clips.
        let starts: [MouseEvent] = entries.map { entry in
            var event = floorSearch(count: events.count, value: entry.sourceStartMs, key: { events[$0].timeMs }).map { events[$0] } ?? events[0]
            event.timeMs = entry.startMs
            return event
        }
        let ascending = isAscending(count: events.count) { events[$0].timeMs }
        var mapped: [MouseEvent] = []
        for entry in entries {
            for i in indices(count: events.count, ascending: ascending, from: entry.sourceStartMs, through: entry.sourceEndMs, key: { events[$0].timeMs }) {
                var event = events[i]
                event.timeMs = entry.toChunk(event.timeMs)
                mapped.append(event)
            }
        }
        func mappedTimes(_ times: [Double]) -> [Double] {
            let sorted = isAscending(count: times.count) { times[$0] }
            return entries.flatMap { entry in
                indices(count: times.count, ascending: sorted, from: entry.sourceStartMs, through: entry.sourceEndMs, key: { times[$0] }).map { entry.toChunk(times[$0]) }
            }
        }

        let points = (starts + mapped)
            .map { CursorPathPoint(timeMs: $0.timeMs, position: $0.position) }
            .sorted { $0.timeMs < $1.timeMs }
        let instant: [TimeRange] = inputs.spring == nil
            ? [TimeRange(startMs: -.infinity, endMs: .infinity)]
            : entries.filter { $0.slice?.disableSmoothMouseMovement == true }.map { TimeRange(startMs: $0.startMs, endMs: $0.endMs) }
        let path = SmoothedCursorPath.plan(
            points: points,
            syncPoints: CameraTrack.cursorSyncPoints(
                events: mapped,
                pointPixelScale: inputs.pointPixelScale,
                cursorImageChangesMs: mappedTimes(inputs.imageChangesMs),
                hoverTimesMs: mappedTimes(inputs.hoverTimesMs)
            ),
            spring: inputs.spring,
            durationMs: min(to, resolver.playbackDurationMs) - chunkStart,
            instantRanges: instant,
            cutTimesMs: entries.filter(\.isAfterCut).map(\.startMs)
        )

        // The events as drawn: each at the instant the smoothed cursor aims at it.
        var drawn = mapped.map { event -> MouseEvent in
            var e = event
            e.timeMs = path.targetTime(of: event.timeMs)
            return e
        }
        if let first = starts.first { drawn.append(first) }
        drawn.sort { $0.timeMs < $1.timeMs }
        let startRotation = from > 0 && inputs.rotationMode == .directional
            ? CursorRotation.rotation(at: resolver.playbackToSource(from), in: history())
            : nil
        var config = CursorConfig()
        config.rotationMode = inputs.rotationMode
        config.rotateOnXMovementRatio = inputs.rotateOnXMovementRatio
        let rotation = CursorRotation.keyframes(drawn, config: config, startRotationRad: startRotation)
        return Chunk(playbackStartMs: chunkStart, path: path, rotation: rotation)
    }

    /// Follow keyframes over the whole recording in source time: where a later chunk's
    /// heading starts.
    private func history() -> [CursorRotationKeyframe] {
        lock.lock()
        if let historyKeyframes {
            lock.unlock()
            return historyKeyframes
        }
        lock.unlock()
        var config = CursorConfig()
        config.rotationMode = inputs.rotationMode
        config.rotateOnXMovementRatio = inputs.rotateOnXMovementRatio
        let keyframes = CursorRotation.keyframes(inputs.cleanedEvents, config: config)
        lock.lock()
        historyKeyframes = keyframes
        lock.unlock()
        return keyframes
    }
}
