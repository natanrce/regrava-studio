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
    /// Modifiers held at that moment (`activeModifiers`); nil when none. Shortcut overlays use
    /// them to show a held modifier before its key is pressed.
    public var activeModifiers: [KeyModifier]?

    public init(kind: MouseEventKind, timeMs: Double, position: Vec2, button: Int = 0, cursorID: String? = nil, activeModifiers: [KeyModifier]? = nil) {
        self.kind = kind
        self.timeMs = timeMs
        self.position = position
        self.button = button
        self.cursorID = cursorID
        self.activeModifiers = activeModifiers?.isEmpty == true ? nil : activeModifiers
    }

    /// Button press or release.
    public var isClick: Bool { kind == .down || kind == .up }
}

public enum MouseProcessing {
    /// "Remove cursor shakes": drops every event whose Manhattan distance to both of the next two
    /// events exceeds `threshold`. A dropped press also drops the next release. 0 = off.
    public static func removeShakes(_ events: [MouseEvent], threshold: Double) -> [MouseEvent] {
        guard threshold != 0 else { return events }
        func isFar(_ a: MouseEvent, _ b: MouseEvent) -> Bool {
            abs(a.position.x - b.position.x) + abs(a.position.y - b.position.y) > threshold
        }
        var result: [MouseEvent] = []
        result.reserveCapacity(events.count)
        var dropNextUp = false
        for (i, event) in events.enumerated() {
            if dropNextUp && event.kind == .up {
                dropNextUp = false
                continue
            }
            guard i + 2 < events.count, isFar(event, events[i + 1]), isFar(event, events[i + 2]) else {
                result.append(event)
                continue
            }
            if event.kind == .down { dropNextUp = true }
        }
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
