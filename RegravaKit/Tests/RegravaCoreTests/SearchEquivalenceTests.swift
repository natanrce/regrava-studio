import Foundation
import Testing
@testable import RegravaCore

/// Binary searches over sorted timelines return what a scan of every element returns.
@Suite struct SearchEquivalenceTests {
    /// Events with repeated timestamps, bursts and long gaps.
    static let events: [MouseEvent] = {
        var out: [MouseEvent] = []
        var t = 100.0
        for i in 0..<400 {
            t += [0.0, 16, 16, 3, 900, 0, 40, 2500][i % 8]
            let x = Double((i * 73) % 1900), y = Double((i * 151) % 1000)
            out.append(MouseEvent(kind: i % 11 == 0 ? .down : .move, timeMs: t, position: Vec2(x, y), cursorID: ["arrow", "pointinghand", "ibeam", nil][i % 4]))
        }
        return out
    }()

    /// Probe times: before the first, after the last, on every timestamp and next to it.
    static func probes(_ times: [Double]) -> [Double] {
        var out = [-1000.0, 0, (times.last ?? 0) + 1, (times.last ?? 0) + 100_000]
        for t in times { out += [t - 350, t - 0.5, t, t + 0.5] }
        return out
    }

    @Test func cursorBoundsMatchesAFullScan() {
        func scan(_ events: [MouseEvent], _ start: Double, _ end: Double) -> Rect2? {
            let floor = MouseProcessing.lastIndex(atOrBefore: start, in: events)
            let inRange = events.indices.filter { events[$0].timeMs >= start && events[$0].timeMs <= end }
            guard let first = floor ?? inRange.first, let last = inRange.last ?? floor else { return nil }
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for i in first...last {
                let p = events[i].position
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return Rect2(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let events = Self.events
        for list in [events, [], Array(events.prefix(1))] {
            for t in Self.probes(list.map(\.timeMs)) {
                for span in [0.0, 350] {
                    #expect(CameraPlanner.cursorBounds(list, from: t, to: t + span) == scan(list, t, t + span))
                }
            }
        }
    }
}
