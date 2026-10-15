import Foundation

/// A burst of mouse activity that fits in the visible area of a zoom.
public struct FocusGroup: Hashable, Sendable {
    public var events: [MouseEvent]
    public var startMs: Double
    public var endMs: Double
    public var bounds: Rect2
    /// Where the camera should look while this group is active.
    public var center: Vec2
}

public enum FocusGrouping {
    /// Splits time-ordered events into consecutive groups whose bounding box never exceeds
    /// `maxExtent`. A group ends when the next event would not fit.
    public static func build(events: [MouseEvent], maxExtent: Size2, endMs: Double) -> [FocusGroup] {
        var groups: [FocusGroup] = []
        var current: [MouseEvent] = []
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0

        func close(at end: Double) {
            guard let first = current.first else { return }
            groups.append(FocusGroup(
                events: current,
                startMs: first.timeMs,
                endMs: end,
                bounds: Rect2(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                center: dwellWeightedCenter(current, endMs: end)
            ))
        }

        for event in events {
            let p = event.position
            if current.isEmpty {
                current = [event]
                minX = p.x; maxX = p.x; minY = p.y; maxY = p.y
                continue
            }
            let nMinX = min(minX, p.x), nMaxX = max(maxX, p.x)
            let nMinY = min(minY, p.y), nMaxY = max(maxY, p.y)
            if nMaxX - nMinX <= maxExtent.width && nMaxY - nMinY <= maxExtent.height {
                current.append(event)
                minX = nMinX; maxX = nMaxX; minY = nMinY; maxY = nMaxY
            } else {
                close(at: event.timeMs)
                current = [event]
                minX = p.x; maxX = p.x; minY = p.y; maxY = p.y
            }
        }
        close(at: endMs)
        return groups
    }

    /// Mean position weighted by how long the cursor stayed at each sample.
    public static func dwellWeightedCenter(_ events: [MouseEvent], endMs: Double) -> Vec2 {
        guard !events.isEmpty else { return .zero }
        var total = 0.0, sx = 0.0, sy = 0.0
        for (i, event) in events.enumerated() {
            let nextTime = i + 1 < events.count ? events[i + 1].timeMs : endMs
            let weight = max(nextTime - event.timeMs, 1)
            total += weight
            sx += event.position.x * weight
            sy += event.position.y * weight
        }
        return Vec2(sx / total, sy / total)
    }

    /// The group that has most recently started at `timeMs`, or the first upcoming one.
    public static func group(at timeMs: Double, in groups: [FocusGroup]) -> FocusGroup? {
        groups.last(where: { $0.startMs <= timeMs }) ?? groups.first
    }
}
