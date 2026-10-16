import Foundation

/// Damped harmonic spring parameters (12 / 1.5, clamp, precision 0.002).
public struct SpringConfig: Codable, Hashable, Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double
    /// "clamp": when the spring would overshoot, damping is raised to critical for that step.
    public var clampOvershoot: Bool
    /// Settle precision, relative to the distance of each target change.
    public var precision: Double

    public init(
        stiffness: Double = 125,
        damping: Double = 12,
        mass: Double = 1.5,
        clampOvershoot: Bool = true,
        precision: Double = 0.002
    ) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
        self.clampOvershoot = clampOvershoot
        self.precision = precision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpringConfig()
        stiffness = c.value(.stiffness, default: d.stiffness)
        damping = c.value(.damping, default: d.damping)
        mass = c.value(.mass, default: d.mass)
        clampOvershoot = c.value(.clampOvershoot, default: d.clampOvershoot)
        precision = c.value(.precision, default: d.precision)
        if precision <= 0 { precision = d.precision }
    }

    /// Camera / screen movement.
    public static let screen = SpringConfig()
    /// Cursor smoothing ("Smooth"); presets inherit clamp and precision.
    public static let cursor = SpringConfig(stiffness: 470, damping: 70, mass: 3)
    /// Jumps directly to the target.
    public static let instant = SpringConfig(stiffness: 1, damping: 1, mass: 0)

    public var isInstant: Bool { mass <= 0 }
}

/// The spring integrator.
public enum SpringMath {
    /// Raises damping to critical when the current velocity heads to the target fast enough to
    /// overshoot it.
    public static func clampedDamping(stiffness: Double, mass: Double, damping: Double, value: Double, velocity: Double, target: Double) -> Double {
        let distance = target - value
        guard velocity * distance > 0 else { return damping }
        let omega = (stiffness / mass).squareRoot()
        guard abs(velocity) > abs(distance) * omega else { return damping }
        return max(damping, 2 * (mass * stiffness).squareRoot())
    }

    /// Advances one spring by `milliseconds` in 1 ms semi-implicit Euler steps.
    ///
    /// The last partial step: when `milliseconds` is fractional, the final step lasts
    /// `ceil(ms) - ms`.
    public static func emulate(
        milliseconds: Double,
        value: Double,
        velocity: Double,
        target: Double,
        config: SpringConfig,
        precision: Double
    ) -> (value: Double, velocity: Double) {
        var x = value
        var v = velocity
        var damping = config.damping
        if config.clampOvershoot {
            damping = clampedDamping(stiffness: config.stiffness, mass: config.mass, damping: damping, value: x, velocity: v, target: target)
        }
        let steps = Int(milliseconds.rounded(.up))
        guard steps <= 10_000 else { return (target, 0) }
        if steps < 1 { return (x, v) }
        for i in 1...steps {
            let step = Double(i)
            let h = step > milliseconds ? (step - milliseconds) / 1000 : 0.001
            let acceleration = (-(x - target) * config.stiffness - v * damping) / config.mass
            let nextV = v + acceleration * h
            let nextX = x + nextV * h
            if abs(nextV) < precision && abs(nextX - target) < precision {
                x = target
                v = 0
                break
            }
            x = nextX
            v = nextV
        }
        return (x, v)
    }

    /// Precision for a move from `value` to `target`: proportional to the distance.
    public static func relativePrecision(from value: Double, to target: Double, precision: Double) -> Double {
        if value == target { return 1 }
        return max(1, abs(value - target)) * precision
    }

    /// Integration step used to measure settle time: one 60 fps frame when stable.
    static func stableStepMs(_ config: SpringConfig) -> Double {
        let frame = 1000.0 / 60
        let omega = (config.stiffness / config.mass).squareRoot()
        let ratio = config.damping / config.mass
        return frame / 1000 * max(omega, ratio) <= 0.5 ? frame : 1
    }

    private static let settleCache = SettleTimeCache()

    /// Time a spring needs to travel 1000 units and come to rest, capped at 20 s.
    public static func settleTime(_ config: SpringConfig) -> Double {
        if config.mass == 0 { return 0 }
        if let cached = settleCache.get(config) { return cached }
        let target = 1000.0
        let precision = relativePrecision(from: 0, to: target, precision: config.precision)
        let step = stableStepMs(config)
        var x = 0.0
        var v = 0.000001
        var elapsed = 0.0
        while x != target && v != 0 {
            let h = step / 1000
            let nextV = v + (-(x - target) * config.stiffness - v * config.damping) / config.mass * h
            let nextX = x + nextV * h
            if abs(nextV) < precision && abs(nextX - target) < precision {
                x = target
                v = 0
            } else {
                x = nextX
                v = nextV
            }
            if x.isNaN || v.isNaN { break }
            elapsed += step
            if elapsed > 20_000 { break }
        }
        settleCache.set(config, elapsed)
        return elapsed
    }
}

private final class SettleTimeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SpringConfig: Double] = [:]

    func get(_ config: SpringConfig) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return values[config]
    }

    func set(_ config: SpringConfig, _ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values[config] = value
    }
}

/// One spring-animated scalar with the state (paths): value, velocity, target and the
/// precision captured when the target last changed.
public struct SpringValue: Hashable, Sendable {
    public var value: Double
    public var velocity: Double
    public private(set) var target: Double
    private var precision: Double = 1

    public init(_ value: Double, velocity: Double = 0) {
        self.value = value
        self.velocity = velocity
        target = value
    }

    public var isAtRest: Bool { value == target && velocity == 0 }

    public mutating func setTarget(_ newTarget: Double, config: SpringConfig) {
        guard newTarget != target else { return }
        precision = SpringMath.relativePrecision(from: value, to: newTarget, precision: config.precision)
        target = newTarget
    }

    public mutating func snapToTarget() {
        value = target
        velocity = 0
    }

    /// `advanceTimeBy`: snaps when the step is longer than the settle time or mass is 0.
    public mutating func advance(by milliseconds: Double, config: SpringConfig) {
        guard milliseconds > 0, !isAtRest else { return }
        if config.mass == 0 || milliseconds >= SpringMath.settleTime(config) {
            snapToTarget()
            return
        }
        (value, velocity) = SpringMath.emulate(
            milliseconds: milliseconds, value: value, velocity: velocity, target: target, config: config, precision: precision
        )
    }

    public mutating func advance(toward newTarget: Double, config: SpringConfig, milliseconds: Double) {
        setTarget(newTarget, config: config)
        advance(by: milliseconds, config: config)
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
