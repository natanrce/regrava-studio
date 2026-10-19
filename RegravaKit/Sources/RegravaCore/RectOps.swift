import Foundation

/// Rectangle operations of the layout code. Top-left origin, y down.
public extension Rect2 {
    static func fromAspectRatio(_ ratio: Double, width: Double) -> Rect2 {
        Rect2(x: 0, y: 0, width: width, height: width / ratio)
    }

    static func fromAspectRatio(_ ratio: Double, height: Double) -> Rect2 {
        Rect2(x: 0, y: 0, width: height * ratio, height: height)
    }

    var shortestSide: Double { min(width, height) }
    var aspectRatio: Double { height == 0 ? 0 : width / height }
    var endX: Double { x + width }
    var endY: Double { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Grows (k > 0) or shrinks (k < 0) by the same amount on every side, based on the shortest
    /// side: s' = s·(1+2k) or s/(1+2|k|).
    func padByRatio(_ k: Double) -> Rect2 {
        let s = shortestSide
        let target = k < 0 ? s / (1 + 2 * abs(k)) : s * (1 + 2 * abs(k))
        let pad = (target - s) / 2
        return Rect2(x: x - pad, y: y - pad, width: width + 2 * pad, height: height + 2 * pad)
    }

    /// Largest size with this aspect inside `box` (no enlarging unless allowed), aligned by `anchor`.
    func fitInside(_ box: Rect2, anchor: Vec2 = Vec2(0.5, 0.5), allowEnlarge: Bool = false) -> Rect2 {
        var k = min(box.width / width, box.height / height)
        if k > 1 && !allowEnlarge { k = 1 }
        let w = width * k, h = height * k
        return Rect2(x: box.x + (box.width - w) * anchor.x, y: box.y + (box.height - h) * anchor.y, width: w, height: h)
    }

    /// Smallest size with this aspect covering `box`, aligned by `anchor`.
    func cover(_ box: Rect2, anchor: Vec2 = Vec2(0.5, 0.5)) -> Rect2 {
        let k = max(box.width / width, box.height / height)
        let w = width * k, h = height * k
        return Rect2(
            x: box.x + (box.x - (w - box.width) - box.x) * anchor.x,
            y: box.y + (box.y - (h - box.height) - box.y) * anchor.y,
            width: w,
            height: h
        )
    }

    /// Same size, placed inside `box` at `anchor` (0 = start, 1 = end).
    func align(_ box: Rect2, _ anchor: Vec2) -> Rect2 {
        Rect2(x: box.x + anchor.x * (box.width - width), y: box.y + anchor.y * (box.height - height), width: width, height: height)
    }

    /// Scaled around a normalized point of the rectangle.
    func scaled(_ s: Double, origin01: Vec2 = Vec2(0, 0)) -> Rect2 {
        Rect2(x: x + origin01.x * width * (1 - s), y: y + origin01.y * height * (1 - s), width: width * s, height: height * s)
    }

    /// Per axis: kept covering `area` when larger, centred in it when smaller.
    func containInZoomArea(_ area: Rect2) -> Rect2 {
        var r = self
        r.x = width > area.width ? clamp(x, area.endX - width, area.x) : area.x + (area.width - width) / 2
        r.y = height > area.height ? clamp(y, area.endY - height, area.y) : area.y + (area.height - height) / 2
        return r
    }

    /// The `zoom`: moves the focus point onto `anchor` (default: the area's centre), scales
    /// around it and contains the result in `area`.
    func zoom(_ level: Double, origin01: Vec2, area: Rect2, anchor: Vec2? = nil) -> Rect2 {
        let p = Vec2(x + origin01.x * width, y + origin01.y * height)
        let t = anchor ?? area.center
        var moved = self
        moved.x += t.x - p.x
        moved.y += t.y - p.y
        return moved.scaled(level, origin01: origin01).containInZoomArea(area)
    }

    func intersection(_ other: Rect2) -> Rect2? {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(endX, other.endX), y1 = min(endY, other.endY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect2(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func containsPoint(_ p: Vec2) -> Bool { p.x >= x && p.x <= endX && p.y >= y && p.y <= endY }
}

public enum LayoutMath {
    /// Best visible point of the zoom area not covered by the camera.
    public static func anchor(zoomArea z: Rect2, camera: Rect2?) -> Vec2 {
        let c = z.center
        guard let camera, !z.isEmpty, let o = z.intersection(camera) else { return c }
        if o.x <= z.x && o.y <= z.y && o.endX >= z.endX && o.endY >= z.endY { return c }
        func strictlyInside(_ p: Vec2) -> Bool { p.x > z.x && p.x < z.endX && p.y > z.y && p.y < z.endY }
        func inO(_ p: Vec2) -> Bool { o.containsPoint(p) }
        var candidates: [Vec2] = []
        if !inO(c) { candidates.append(c) }
        if o.y > z.y { candidates.append(Vec2(z.x + z.width / 2, (z.y + o.y) / 2)) }
        if o.endY < z.endY { candidates.append(Vec2(z.x + z.width / 2, (o.endY + z.endY) / 2)) }
        if o.x > z.x { candidates.append(Vec2((z.x + o.x) / 2, z.y + z.height / 2)) }
        if o.endX < z.endX { candidates.append(Vec2((o.endX + z.endX) / 2, z.y + z.height / 2)) }
        candidates = candidates.filter { strictlyInside($0) && !inO($0) }
        /// Distance to the zoom area's edges, cut short by O when it lies between the point and an edge.
        func breathingRoom(_ p: Vec2) -> Double {
            var left = p.x - z.x, right = z.endX - p.x, top = p.y - z.y, bottom = z.endY - p.y
            let withinY = p.y >= o.y && p.y <= o.endY, withinX = p.x >= o.x && p.x <= o.endX
            if withinY && o.endX <= p.x { left = min(left, p.x - o.endX) }
            if withinY && o.x >= p.x { right = min(right, o.x - p.x) }
            if withinX && o.endY <= p.y { top = min(top, p.y - o.endY) }
            if withinX && o.y >= p.y { bottom = min(bottom, o.y - p.y) }
            return min(left, right, top, bottom)
        }
        var best: Vec2?
        var bestRoom = -Double.infinity
        for p in candidates {
            let room = breathingRoom(p)
            if room > bestRoom + 1e-9 || (abs(room - bestRoom) <= 1e-9 && (best.map { p.distance(to: c) < $0.distance(to: c) } ?? true)) {
                best = p
                bestRoom = room
            }
        }
        return best ?? c
    }

    /// Linear map of `v` from [a, b] to [c, d], clamped.
    static func mapRange(_ v: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        guard b != a else { return c }
        return c + clamp((v - a) / (b - a), 0, 1) * (d - c)
    }
}
