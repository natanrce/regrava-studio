import Foundation

/// Figma-style smooth corners, the corner shape for the screen, the camera and the shortcut keys.
///
/// A corner of radius `r` with smoothing `s` starts curving `(1 + s)·r` from the corner. The
/// shader traces the contour from a 16-entry table of radial distances (`curvatureLut`).
public enum SmoothCorners {
    public static let lutSize = 16

    /// How far from the corner the curve starts.
    public static func extent(width: Double, height: Double, radius: Double, smoothing: Double) -> Double {
        let half = min(width, height) / 2
        return min(half, (1 + smoothing) * min(radius, half))
    }

    /// The curvature table for a `width × height` rect with corner `radius`.
    public static func lut(width: Double, height: Double, radius: Double, smoothing: Double = 1) -> [Double] {
        guard radius > 0, smoothing > 0 else { return Array(repeating: 1, count: lutSize) }
        let w = width / radius, h = height / radius
        let side = min(min(w, h), 2 * extent(width: w, height: h, radius: 1, smoothing: smoothing))
        return table(side: side, smoothing: smoothing)
    }

    private static var cache: [Int: [Double]] = [:]
    private static let lock = NSLock()

    /// Cached by the side quantised to 1/256.
    static func table(side: Double, smoothing: Double) -> [Double] {
        let key = Int((side * 256).rounded()) &* 1000 &+ Int((smoothing * 999).rounded())
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let result = computeTable(side: side, smoothing: smoothing)
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    /// The top-right corner of an `S × S` square (y down) as a polyline, then rays cast from
    /// `(S − p, p)`.
    static func computeTable(side S: Double, smoothing s: Double) -> [Double] {
        let rad = min(1, S / 2)
        let p = min(S / 2, (1 + s) * rad)
        let arc: Double, bez: Double
        if rad > S / 4 {
            let k = (rad - S / 4) / (S / 4)
            arc = 90 * (1 - s * (1 - k))
            bez = 45 * s * (1 - k)
        } else {
            arc = 90 * (1 - s)
            bez = 45 * s
        }
        let deg = Double.pi / 180
        let theta = (90 - arc) / 2
        let c = rad * tan(theta / 2 * deg) * cos(bez * deg)
        let d = c * tan(bez * deg)
        let arcLength = sin(arc / 2 * deg) * rad * 2.0.squareRoot()
        let b = (p - arcLength - c - d) / 3
        let a = 2 * b

        var points: [(Double, Double)] = [(S / 2, 0), (S - p, 0)]
        func cubic(_ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double), _ p3: (Double, Double)) {
            for i in 1...64 {
                let t = Double(i) / 64, u = 1 - t
                let x = u * u * u * p0.0 + 3 * u * u * t * p1.0 + 3 * u * t * t * p2.0 + t * t * t * p3.0
                let y = u * u * u * p0.1 + 3 * u * u * t * p1.1 + 3 * u * t * t * p2.1 + t * t * t * p3.1
                points.append((x, y))
            }
        }
        cubic((S - p, 0), (S - p + a, 0), (S - p + a + b, 0), (S - p + a + b + c, d))
        // Arc around (S − rad, rad) from 270° + θ to 360° − θ (y down).
        let from = (270 + theta) * deg, to = (360 - theta) * deg
        if to > from {
            for i in 1...64 {
                let angle = from + (to - from) * Double(i) / 64
                points.append((S - rad + rad * cos(angle), rad + rad * sin(angle)))
            }
        }
        cubic((S - d, p - a - b - c), (S, p - a - b), (S, p - a), (S, p))
        points.append((S, S / 2))

        let origin = (S - p, p)
        var lut = [1.0]
        for i in 1..<lutSize {
            let phi = Double(i) / Double(lutSize - 1) * .pi / 4
            let dir = (sin(phi), -cos(phi))
            var best = Double.infinity
            for j in 1..<points.count {
                let q0 = points[j - 1], q1 = points[j]
                // origin + t·dir = q0 + u·(q1 − q0)
                let ex = q1.0 - q0.0, ey = q1.1 - q0.1
                let det = dir.0 * -ey - dir.1 * -ex
                guard abs(det) > 1e-12 else { continue }
                let rx = q0.0 - origin.0, ry = q0.1 - origin.1
                let t = (rx * -ey - ry * -ex) / det
                let u = (dir.0 * ry - dir.1 * rx) / det
                if t > 0, u >= -1e-9, u <= 1 + 1e-9 { best = min(best, t) }
            }
            lut.append(best.isFinite ? best / p : 1)
        }
        return lut
    }
}
