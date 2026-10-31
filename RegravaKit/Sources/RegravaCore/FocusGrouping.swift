import Foundation

/// A burst of mouse activity that fits in the visible area of a zoom.
public struct FocusGroup: Hashable, Sendable {
    public var startMs: Double
    /// When the next group took over (its first event); nil for the last group.
    public var finishedMs: Double?
    public var bounds: Rect2
    /// Where the camera should look while this group is active.
    public var center: Vec2
}

public enum FocusGrouping {
    /// How long the last event of the last group counts for its centre.
    public static let openGroupLastEventMs = 100.0

    /// Splits time-ordered events into consecutive groups whose bounding box never exceeds
    /// `maxExtent`. A group ends when the next event would not fit.
    public static func build(events: [MouseEvent], maxExtent: Size2) -> [FocusGroup] {
        var groups: [FocusGroup] = []
        var current: [MouseEvent] = []
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0

        func close(finishedMs: Double?) {
            guard let first = current.first else { return }
            groups.append(FocusGroup(
                startMs: first.timeMs,
                finishedMs: finishedMs,
                bounds: Rect2(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                center: dwellWeightedCenter(current, finishedMs: finishedMs)
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
                close(finishedMs: event.timeMs)
                current = [event]
                minX = p.x; maxX = p.x; minY = p.y; maxY = p.y
            }
        }
        close(finishedMs: nil)
        return groups
    }

    /// Mean position weighted by how long the cursor stayed at each sample: until the next
    /// sample, the last one until `finishedMs` (or for 100 ms in a group still open).
    public static func dwellWeightedCenter(_ events: [MouseEvent], finishedMs: Double?) -> Vec2 {
        var total = 0.0, sx = 0.0, sy = 0.0
        for (i, event) in events.enumerated() {
            let nextTime = i + 1 < events.count ? events[i + 1].timeMs : finishedMs ?? event.timeMs + openGroupLastEventMs
            let weight = (nextTime - event.timeMs) / 1000
            total += weight
            sx += event.position.x * weight
            sy += event.position.y * weight
        }
        return Vec2(sx / total, sy / total)
    }

    /// The group that has most recently started at `timeMs`, or the first upcoming one.
    public static func group(at timeMs: Double, in groups: [FocusGroup]) -> FocusGroup? {
        let i = floorSearch(count: groups.count, value: timeMs, key: { groups[$0].startMs })
            ?? ceilSearch(count: groups.count, value: timeMs, key: { groups[$0].startMs })
        return i.map { groups[$0] }
    }
}
