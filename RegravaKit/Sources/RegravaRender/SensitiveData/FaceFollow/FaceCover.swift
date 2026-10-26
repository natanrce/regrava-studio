import CoreGraphics
import Foundation

extension SD {
    /// The vertical scroll of one stripe at every sample that measured stripes: `dy` is nil when the
    /// stripe's shift is unknown at that sample (positive dy: content moved down).
    static func scrollSteps(ofStripe stripe: Int, in timeline: ChangeTimeline) -> [(timeMs: Double, dy: CGFloat?)] {
        timeline.samples.filter { !$0.isEverything }.map { sample in
            var dy: CGFloat?
            if !sample.stripeShiftsPx.isEmpty {
                let shift = sample.stripeShiftsPx[stripe]
                dy = shift == Int16.min ? nil : Double(Int32(shift)) * -0.125
            }
            return (Double(sample.timeMs), dy)
        }
    }

    /// A track lost while the page under it was scrolling keeps moving with the scroll (at its last or
    /// first point) until it has travelled its own size or left the frame.
    static func carriedAlongScroll(_ track: FaceFollower.Track, scrollSteps: [(timeMs: Double, dy: CGFloat?)], frameRect: CGRect) -> FaceFollower.Track {
        guard let firstBox = track.boxes.first, let first = track.path.first, let last = track.path.last else { return track }
        let reach = track.boxes.map { max($0.rect.width, $0.rect.height) }.max() ?? max(firstBox.rect.width, firstBox.rect.height)
        func isScrolling(from: Double, to: Double) -> Bool {
            var moved: CGFloat = 0
            for step in scrollSteps where from < step.timeMs && step.timeMs <= to { moved = moved + abs(step.dy ?? 0) }
            return (to - from) * 0.2 <= moved
        }
        /// The path point nearest in time to the first box (the box is drawn around it).
        func anchor() -> (timeMs: Double, point: CGPoint) {
            var best = track.path[0]
            for p in track.path.dropFirst() where !(abs(best.timeMs - firstBox.timeMs) <= abs(p.timeMs - firstBox.timeMs)) { best = p }
            return best
        }
        var path = track.path
        var endMs = track.endMs
        var startMs = track.startMs
        if track.isLostAtEnd, isScrolling(from: last.timeMs + -100, to: last.timeMs) {
            var carried: [(timeMs: Double, point: CGPoint)] = []
            var moved: CGFloat = 0
            for step in scrollSteps.filter({ last.timeMs < $0.timeMs }) {
                guard let dy = step.dy, dy != 0 else { break }
                moved = moved + dy
                carried.append((step.timeMs, CGPoint(x: last.point.x, y: last.point.y + moved)))
                if reach <= abs(moved) { break }
                let a = anchor()
                let box = firstBox.rect.offsetBy(dx: last.point.x - a.point.x, dy: (last.point.y + moved) - a.point.y)
                if !box.intersects(frameRect) { break }
            }
            path.append(contentsOf: carried)
            if let end = carried.last { endMs = end.timeMs < track.endMs ? track.endMs : end.timeMs }
        }
        if track.isLostAtStart, isScrolling(from: first.timeMs, to: first.timeMs + 100) {
            let before = scrollSteps.filter { $0.timeMs <= first.timeMs }
            var times: [Double] = []
            if before.count > 1 {
                for i in stride(from: before.count - 2, through: 0, by: -1) { times.append(before[i].timeMs) }
            }
            times.append(contentsOf: [before.isEmpty ? first.timeMs : before[0].timeMs + -16.666666666666668])
            // Each shift happened between the previous sample and this one, so going back it moves
            // the face at the previous sample's time.
            let steps = zip(before.reversed(), times).map { (timeMs: $1, dy: $0.dy) }
            var carried: [(timeMs: Double, point: CGPoint)] = []
            var moved: CGFloat = 0
            for step in steps {
                guard let dy = step.dy, dy != 0 else { break }
                moved = moved - dy
                carried.append((step.timeMs, CGPoint(x: first.point.x, y: first.point.y + moved)))
                if reach <= abs(moved) { break }
                let a = anchor()
                let box = firstBox.rect.offsetBy(dx: first.point.x - a.point.x, dy: (first.point.y + moved) - a.point.y)
                if !box.intersects(frameRect) { break }
            }
            var joined = Array(carried.reversed())
            joined.append(contentsOf: path)
            path = joined
            if let start = carried.last { startMs = track.startMs <= start.timeMs ? track.startMs : start.timeMs }
        }
        return FaceFollower.Track(startMs: startMs, endMs: endMs, path: path, boxes: track.boxes,
                                  isLostAtStart: track.isLostAtStart, isLostAtEnd: track.isLostAtEnd)
    }

    /// The path with the fewest changes of slope that stays within `lows...highs` at every time
    /// (a funnel through the bounds); the value starts at the middle of the bounds that agree from the start.
    static func steadiestPath(timesMs: [Double], lows: [CGFloat], highs: [CGFloat]) -> [(timeMs: Double, value: CGFloat)] {
        let n = timesMs.count
        if n < 2 { return [(timesMs[0], (lows[0] + highs[0]) * 0.5)] }
        var low = lows[0]
        var high = highs[0]
        var i = 0
        while true {
            let a = lows[i + 1]
            let nextLow = low <= a ? a : low
            let b = highs[i + 1]
            let nextHigh = b < high ? b : high
            if nextHigh < nextLow { break }
            i += 1
            low = nextLow
            high = nextHigh
            if i == n - 1 { break }
        }
        var result: [(timeMs: Double, value: CGFloat)] = [(timesMs[0], (high + low) * 0.5)]
        func slope(_ lowSlope: Double, _ highSlope: Double) -> Double {
            (highSlope >= 0 && lowSlope <= 0) ? 0 : (highSlope + lowSlope) * 0.5
        }
        var lowSlope = -Double.infinity
        var highSlope = Double.infinity
        var k = 0
        var j = 1
        outer: while j < n {
            let anchor = result[result.count - 1]
            let dt = timesMs[j] - anchor.timeMs
            if !(dt > 0) {
                j += 1
                continue
            }
            let sLow = (lows[j] - anchor.value) / dt
            let newLow = lowSlope <= sLow ? sLow : lowSlope
            let sHigh = (highs[j] - anchor.value) / dt
            let newHigh = sHigh < highSlope ? sHigh : highSlope
            if newLow <= newHigh {
                k = j
                lowSlope = newLow
                highSlope = newHigh
                j += 1
                continue
            }
            let tk = timesMs[k]
            result.append((tk, anchor.value + slope(lowSlope, highSlope) * (tk - anchor.timeMs)))
            j = k + 1
            if j >= n {
                lowSlope = -Double.infinity
                highSlope = Double.infinity
                break outer
            }
            while true {
                let from = result[result.count - 1]
                let dt2 = timesMs[j] - from.timeMs
                if !(dt2 > 0) {
                    lowSlope = -Double.infinity
                    highSlope = Double.infinity
                    j += 1
                    continue outer
                }
                let lo = Double.maximum((lows[j] - from.value) / dt2, -Double.infinity)
                let hi = Double.minimum((highs[j] - from.value) / dt2, Double.infinity)
                if lo <= hi {
                    k = j
                    lowSlope = lo
                    highSlope = hi
                    j += 1
                    continue outer
                }
                let tk2 = timesMs[k]
                result.append((tk2, from.value + (tk2 - from.timeMs) * 0))
            }
        }
        let end = result[result.count - 1]
        let lastTime = timesMs[n - 1]
        if end.timeMs < lastTime {
            result.append((lastTime, end.value + slope(lowSlope, highSlope) * (lastTime - end.timeMs)))
        }
        return result
    }

    /// Linear interpolation along a path, clamped to its ends.
    static func value(of path: [(timeMs: Double, value: CGFloat)], atMs: Double) -> CGFloat {
        precondition(!path.isEmpty)
        for i in path.indices where atMs <= path[i].timeMs {
            if i == 0 { return path[0].value }
            let a = path[i - 1]
            let b = path[i]
            var span = b.timeMs - a.timeMs
            if span <= 1e-09 { span = 1e-09 }
            return a.value + (b.value - a.value) * ((atMs - a.timeMs) / span)
        }
        return path[path.count - 1].value
    }

    /// A square cover per path point that moves and resizes as little as possible: the face box around
    /// each point (union of the boxes within 1500 ms), its size kept between 1.12× and 1.3× the face, and
    /// its centre within `0.65·(size − face)/√2`; vertical motion follows the measured scroll.
    static func steadyFaceCover(_ track: FaceFollower.Track, scrollSteps: [(timeMs: Double, dy: CGFloat?)]) -> [(timeMs: Double, rect: CGRect)] {
        var points: [(timeMs: Double, point: CGPoint)] = []
        for p in track.path.sorted(by: { $0.timeMs < $1.timeMs }) where (points.last?.timeMs ?? -Double.infinity) < p.timeMs {
            points.append(p)
        }
        func point(atMs t: Double) -> CGPoint {
            precondition(!points.isEmpty)
            for i in points.indices where t <= points[i].timeMs {
                if i == 0 { return points[0].point }
                let a = points[i - 1]
                let b = points[i]
                let f = (t - a.timeMs) / (b.timeMs - a.timeMs)
                return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f)
            }
            return points[points.count - 1].point
        }
        let relative = track.boxes.map { box -> (timeMs: Double, rect: CGRect) in
            let p = point(atMs: box.timeMs)
            return (box.timeMs, box.rect.offsetBy(dx: -p.x, dy: -p.y))
        }
        let times = points.map { $0.timeMs }
        var centers: [(x: CGFloat, y: CGFloat)] = []
        var extents: [CGFloat] = []
        for p in points {
            var near = CGRect.null
            for r in relative.filter({ abs($0.timeMs - p.timeMs) <= 1500 }).map({ $0.rect }) { near = near.union(r) }
            if near.isNull, !relative.isEmpty {
                var best = relative[0]
                for r in relative.dropFirst() where abs(r.timeMs - p.timeMs) < abs(best.timeMs - p.timeMs) { best = r }
                near = best.rect
            }
            let box = near.offsetBy(dx: p.point.x, dy: p.point.y)
            centers.append((box.midX, box.midY))
            extents.append(max(box.width, box.height))
        }
        let size = steadiestPath(timesMs: times, lows: extents.map { $0 * 1.12 }, highs: extents.map { $0 * 1.3 })
        var slack: [CGFloat] = []
        for i in times.indices { slack.append(((value(of: size, atMs: times[i]) - extents[i]) * 0.65) / 1.4142135623730951) }
        var xLows: [CGFloat] = []
        var xHighs: [CGFloat] = []
        for i in times.indices { xLows.append(centers[i].x - slack[i]) }
        for i in times.indices { xHighs.append(centers[i].x + slack[i]) }
        let xs = steadiestPath(timesMs: times, lows: xLows, highs: xHighs)

        var scroll: [(timeMs: Double, value: CGFloat)] = [(times[0], 0)]
        var previousMs = times[0]
        for step in scrollSteps {
            let t = step.timeMs
            guard times[0] < t, !(t > times[times.count - 1]) else { continue }
            let dy: CGFloat
            if let measured = step.dy { dy = measured } else { dy = point(atMs: t).y - point(atMs: previousMs).y }
            scroll.append((t, dy + scroll[scroll.count - 1].value))
            previousMs = t
        }
        let offsets = times.map { value(of: scroll, atMs: $0) }
        var yLows: [CGFloat] = []
        var yHighs: [CGFloat] = []
        for i in times.indices { yLows.append((centers[i].y - slack[i]) - offsets[i]) }
        for i in times.indices { yHighs.append((centers[i].y + slack[i]) - offsets[i]) }
        let ys = steadiestPath(timesMs: times, lows: yLows, highs: yHighs)

        var cover: [(timeMs: Double, rect: CGRect)] = []
        for i in times.indices {
            let t = times[i]
            let s = value(of: size, atMs: t)
            let y = value(of: ys, atMs: t)
            let x = value(of: xs, atMs: t)
            let r = CGRect(x: x - s * 0.5, y: (y + offsets[i]) - s * 0.5, width: s, height: s)
            if let last = cover.last?.rect, abs(last.minX - r.minX) < 0.5, abs(last.minY - r.minY) < 0.5, abs(last.width - r.width) < 0.5 { continue }
            cover.append((t, r))
        }
        return cover
    }
}
