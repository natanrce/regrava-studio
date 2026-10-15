import Foundation

/// Damped harmonic spring parameters.
public struct SpringConfig: Codable, Hashable, Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double
    /// Stop at the target instead of overshooting past it.
    public var clampOvershoot: Bool
    /// Velocity / distance under which the spring is considered settled.
    public var precision: Double

    public init(
        stiffness: Double = 125,
        damping: Double = 12,
        mass: Double = 1.5,
        clampOvershoot: Bool = true,
        precision: Double = 0.01
    ) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
        self.clampOvershoot = clampOvershoot
        self.precision = precision
    }

    /// Camera / screen movement.
    public static let screen = SpringConfig()
    /// Cursor smoothing: heavier and well damped so jitter disappears without lag spikes.
    public static let cursor = SpringConfig(stiffness: 470, damping: 70, mass: 3, clampOvershoot: false)
    /// Jumps directly to the target.
    public static let instant = SpringConfig(stiffness: 1, damping: 1, mass: 0)

    public var isInstant: Bool { mass <= 0 }
}

/// One spring-animated scalar, integrated with semi-implicit Euler in 1 ms steps.
public struct SpringValue: Hashable, Sendable {
    public var value: Double
    public var velocity: Double

    public init(_ value: Double, velocity: Double = 0) {
        self.value = value
        self.velocity = velocity
    }

    public mutating func advance(toward target: Double, config: SpringConfig, milliseconds: Double) {
        if config.isInstant {
            value = target
            velocity = 0
            return
        }
        var remaining = milliseconds
        while remaining > 0 {
            if value == target && velocity == 0 { return }
            let stepMs = min(1, remaining)
            remaining -= stepMs
            let h = stepMs / 1000
            let before = value - target
            let acceleration = (-config.stiffness * before - config.damping * velocity) / config.mass
            velocity += acceleration * h
            value += velocity * h
            let after = value - target
            if config.clampOvershoot && before * after < 0 {
                value = target
                velocity = 0
            } else if abs(velocity) < config.precision && abs(after) < config.precision {
                value = target
                velocity = 0
            }
        }
    }
}

/// Convenience bundle of springs animating a rectangle.
public struct SpringRect: Hashable, Sendable {
    public var x: SpringValue
    public var y: SpringValue
    public var width: SpringValue
    public var height: SpringValue

    public init(_ rect: Rect2) {
        x = SpringValue(rect.x)
        y = SpringValue(rect.y)
        width = SpringValue(rect.width)
        height = SpringValue(rect.height)
    }

    public var rect: Rect2 {
        Rect2(x: x.value, y: y.value, width: width.value, height: height.value)
    }

    public mutating func advance(toward target: Rect2, config: SpringConfig, milliseconds: Double) {
        x.advance(toward: target.x, config: config, milliseconds: milliseconds)
        y.advance(toward: target.y, config: config, milliseconds: milliseconds)
        width.advance(toward: target.width, config: config, milliseconds: milliseconds)
        height.advance(toward: target.height, config: config, milliseconds: milliseconds)
    }
}

public struct SpringPoint: Hashable, Sendable {
    public var x: SpringValue
    public var y: SpringValue

    public init(_ point: Vec2) {
        x = SpringValue(point.x)
        y = SpringValue(point.y)
    }

    public var point: Vec2 { Vec2(x.value, y.value) }

    public mutating func advance(toward target: Vec2, config: SpringConfig, milliseconds: Double) {
        x.advance(toward: target.x, config: config, milliseconds: milliseconds)
        y.advance(toward: target.y, config: config, milliseconds: milliseconds)
    }
}
