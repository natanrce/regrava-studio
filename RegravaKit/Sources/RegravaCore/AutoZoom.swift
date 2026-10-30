import Foundation

/// Rules used to turn clicks into zoom ranges.
public struct AutoZoomConfig: Codable, Hashable, Sendable {
    /// Zoom starts this long before each click.
    public var leadMs: Double
    /// Zoom lasts this long after each click.
    public var holdMs: Double
    /// Clicks in the final part of the recording are ignored.
    public var ignoreClicksInLastMs: Double
    /// Zooms end at least this long before the end of the recording.
    public var endMarginMs: Double
    /// Zooms separated by less than this are merged.
    public var mergeGapMs: Double
    public var scale: Double
    public var isEnabled: Bool

    public init(
        leadMs: Double = 300,
        holdMs: Double = 2500,
        ignoreClicksInLastMs: Double = 1000,
        endMarginMs: Double = 800,
        mergeGapMs: Double = 2500,
        scale: Double = 2,
        isEnabled: Bool = true
    ) {
        self.leadMs = leadMs
        self.holdMs = holdMs
        self.ignoreClicksInLastMs = ignoreClicksInLastMs
        self.endMarginMs = endMarginMs
        self.mergeGapMs = mergeGapMs
        self.scale = scale
        self.isEnabled = isEnabled
    }
}

public struct TimeSpan: Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }
}

public enum Intervals {
    /// Sorts spans and merges those that overlap or are separated by at most `gap`.
    public static func merge(_ spans: [TimeSpan], gap: Double = 0) -> [TimeSpan] {
        let sorted = spans.filter { $0.start <= $0.end }.sorted { $0.start < $1.start }
        var merged: [TimeSpan] = []
        for span in sorted {
            if let last = merged.last, span.start <= last.end + gap {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

public enum AutoZoomGenerator {
    public static func generate(events: [MouseEvent], durationMs: Double, config: AutoZoomConfig) -> [ZoomRange] {
        guard config.isEnabled, durationMs > 0 else { return [] }
        let latestClick = durationMs - config.ignoreClicksInLastMs
        let latestEnd = durationMs - config.endMarginMs
        let spans = events
            .filter { $0.kind == .down && $0.timeMs < latestClick }
            .map { click -> TimeSpan in
                let t = click.timeMs.rounded(.down)
                return TimeSpan(max(t - config.leadMs, 1), min(t + config.holdMs, latestEnd))
            }
        return Intervals.merge(spans, gap: config.mergeGapMs)
            .filter { $0.end - $0.start >= ZoomRange.minimumDurationMs }
            .map {
                ZoomRange(
                    startMs: $0.start.rounded(.down),
                    endMs: $0.end.rounded(.down),
                    scale: config.scale,
                    mode: .auto,
                    isGenerated: true
                )
            }
    }
}
