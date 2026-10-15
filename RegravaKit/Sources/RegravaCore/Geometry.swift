import Foundation

/// 2D point / vector. Coordinates are top-left origin unless stated otherwise.
public struct Vec2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.init(x, y)
    }

    public static let zero = Vec2(0, 0)
    public static let center01 = Vec2(0.5, 0.5)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }

    public func distance(to other: Vec2) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    public func lerp(to other: Vec2, _ t: Double) -> Vec2 {
        Vec2(x + (other.x - x) * t, y + (other.y - y) * t)
    }
}

public struct Size2: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double { height == 0 ? 1 : width / height }
}

/// Axis-aligned rectangle, top-left origin.
public struct Rect2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(size: Size2) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Vec2 { Vec2(midX, midY) }
    public var size: Size2 { Size2(width: width, height: height) }

    public func insetBy(_ d: Double) -> Rect2 {
        Rect2(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    /// Point at a normalized (0...1) position inside the rectangle.
    public func point(at unit: Vec2) -> Vec2 {
        Vec2(x + unit.x * width, y + unit.y * height)
    }

    public func lerp(to other: Rect2, _ t: Double) -> Rect2 {
        Rect2(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }

    /// Largest rectangle with `content`'s aspect ratio that fits in `bounds`, centered.
    public static func aspectFit(_ content: Size2, in bounds: Rect2) -> Rect2 {
        guard content.width > 0, content.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return Rect2(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

@inlinable
public func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

public enum ZoomGeometry {
    /// Where the screen image must be drawn so that it appears zoomed.
    ///
    /// The resting screen rectangle is scaled by `scale`, translated so the focus point
    /// (normalized position inside the screen) lands on the center of `area`, and then
    /// clamped per axis: if the scaled screen is larger than `area` it must keep covering
    /// it (no empty gaps), otherwise it must stay fully inside it.
    public static func zoomedScreenRect(rest: Rect2, scale: Double, focus: Vec2, area: Rect2) -> Rect2 {
        guard scale > 1 else { return rest }
        let w = rest.width * scale
        let h = rest.height * scale
        let fx = clamp(focus.x, 0, 1)
        let fy = clamp(focus.y, 0, 1)
        var x = area.midX - fx * w
        var y = area.midY - fy * h
        x = w >= area.width ? clamp(x, area.maxX - w, area.minX) : clamp(x, area.minX, area.maxX - w)
        y = h >= area.height ? clamp(y, area.maxY - h, area.minY) : clamp(y, area.minY, area.maxY - h)
        return Rect2(x: x, y: y, width: w, height: h)
    }
}
