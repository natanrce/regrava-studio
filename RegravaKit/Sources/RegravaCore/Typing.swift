import Foundation

/// A key press or release during the recording (`recording.keystrokes`: "keyDown" / "keyUp").
public struct Keystroke: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case down, up }

    public var kind: Kind
    public var timeMs: Double

    public init(kind: Kind, timeMs: Double) {
        self.kind = kind
        self.timeMs = timeMs
    }
}

/// Typing detection.
public enum Typing {
    /// Window looked back on.
    public static let activeWindowMs = 1800.0
    /// Key presses needed in that window.
    public static let activeMinimumKeyDowns = 3

    /// Whether the user is typing at `t`: at least 3 key presses in the last 1.8 s and the
    /// mouse has not moved or clicked since the last keystroke.
    public static func isActivelyTyping(at t: Double, keystrokes: [Keystroke], mouseEvents: [MouseEvent]) -> Bool {
        guard let first = ceilSearch(count: keystrokes.count, value: t - activeWindowMs, key: { keystrokes[$0].timeMs }),
              keystrokes[first].timeMs <= t else { return false }
        var last = first
        var downs = 0
        while last < keystrokes.count && keystrokes[last].timeMs <= t {
            if keystrokes[last].kind == .down { downs += 1 }
            last += 1
        }
        last -= 1
        guard downs >= activeMinimumKeyDowns else { return false }
        if let i = floorSearch(count: mouseEvents.count, value: t, key: { mouseEvents[$0].timeMs }),
           mouseEvents[i].timeMs > keystrokes[last].timeMs {
            return false
        }
        return true
    }

    /// Gap that ends a run of keystrokes.
    public static let suggestionGapMs = 500.0
    /// Shortest run worth suggesting.
    public static let suggestionMinimumMs = 1500.0
    /// Keystrokes per second a run needs.
    public static let suggestionMinimumRate = 2.0

    /// "Speed up typing" ranges: runs of keystrokes less than 500 ms apart lasting at least 1.5
    /// s at 2 or more keystrokes per second.
    public static func suggestions(_ keystrokes: [Keystroke]) -> [TimeRange] {
        func qualifies(_ run: ArraySlice<Keystroke>) -> Bool {
            let span = run.last!.timeMs - run.first!.timeMs
            return span >= suggestionMinimumMs && Double(run.count) / (span / 1000) >= suggestionMinimumRate
        }
        var ranges: [TimeRange] = []
        var start = 0
        guard !keystrokes.isEmpty else { return [] }
        for i in 1...keystrokes.count {
            if i < keystrokes.count && keystrokes[i].timeMs - keystrokes[i - 1].timeMs < suggestionGapMs { continue }
            let run = keystrokes[start..<i]
            if qualifies(run) { ranges.append(TimeRange(startMs: run.first!.timeMs, endMs: run.last!.timeMs)) }
            start = i
        }
        return ranges
    }
}
