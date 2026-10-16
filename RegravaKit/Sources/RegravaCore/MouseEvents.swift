import Foundation

public enum MouseEventKind: String, Codable, Sendable {
    case move
    case down
    case up
    /// Movement while a button is held ("mouseDragged").
    case drag
}

/// A mouse sample in recorded-video pixel space (top-left origin), relative to recording start.
public struct MouseEvent: Codable, Hashable, Sendable {
    public var kind: MouseEventKind
    public var timeMs: Double
    public var position: Vec2
    public var button: Int
    /// System cursor shown at that moment, named ("arrow", "iBeam", "pointingHand"…, or
    /// "custom-N" for a saved image). nil = unknown (arrow).
    public var cursorID: String?

    public init(kind: MouseEventKind, timeMs: Double, position: Vec2, button: Int = 0, cursorID: String? = nil) {
        self.kind = kind
        self.timeMs = timeMs
        self.position = position
        self.button = button
        self.cursorID = cursorID
    }

    /// Button press or release.
    public var isClick: Bool { kind == .down || kind == .up }
}

public enum MouseProcessing {
    /// Removes isolated single-sample jumps: a move that is far from both neighbours while
    /// the neighbours themselves are close to each other (tracking glitches, warps).
    public static func removeSpikes(_ events: [MouseEvent], threshold: Double) -> [MouseEvent] {
        guard threshold > 0, events.count >= 3 else { return events }
        var result: [MouseEvent] = [events[0]]
        result.reserveCapacity(events.count)
        for i in 1..<(events.count - 1) {
            let previous = events[i - 1].position
            let current = events[i]
            let next = events[i + 1].position
            let isSpike = current.kind == .move
                && current.position.distance(to: previous) > threshold
                && current.position.distance(to: next) > threshold
                && previous.distance(to: next) <= threshold
            if !isSpike { result.append(current) }
        }
        result.append(events[events.count - 1])
        return result
    }

    /// Keeps a move only when it is at least `minDistance` away from the last kept sample.
    /// Clicks are always kept.
    public static func downsample(_ events: [MouseEvent], minDistance: Double) -> [MouseEvent] {
        guard minDistance > 0 else { return events }
        var result: [MouseEvent] = []
        var lastKept: MouseEvent?
        for event in events {
            guard let last = lastKept else {
                result.append(event)
                lastKept = event
                continue
            }
            if event.isClick || event.position.distance(to: last.position) >= minDistance {
                result.append(event)
                lastKept = event
            }
        }
        return result
    }

    /// Index of the last event whose time is <= `timeMs` (events sorted by time).
    public static func lastIndex(atOrBefore timeMs: Double, in events: [MouseEvent]) -> Int? {
        var low = 0
        var high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].timeMs <= timeMs { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Cursor position at `timeMs`, linearly interpolated between samples.
    public static func position(at timeMs: Double, in events: [MouseEvent]) -> Vec2? {
        guard let first = events.first else { return nil }
        guard let i = lastIndex(atOrBefore: timeMs, in: events) else { return first.position }
        let a = events[i]
        guard i + 1 < events.count else { return a.position }
        let b = events[i + 1]
        let span = b.timeMs - a.timeMs
        guard span > 0 else { return b.position }
        return a.position.lerp(to: b.position, clamp((timeMs - a.timeMs) / span, 0, 1))
    }
}
