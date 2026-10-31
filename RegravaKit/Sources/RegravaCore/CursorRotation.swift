import Foundation

/// The rotation a moving cursor adds to its base rotation ("Rotate while moving"), as
/// keyframes in the time of the events it is planned from. Positive turns clockwise.
public struct CursorRotationKeyframe: Hashable, Sendable {
    public var timeMs: Double
    public var rotationRad: Double

    public init(timeMs: Double, rotationRad: Double) {
        self.timeMs = timeMs
        self.rotationRad = rotationRad
    }
}

public enum CursorRotation {
    /// Integration step, in milliseconds.
    public static let stepMs = 16.0
    /// Keyframes closer than this to the last emitted angle are held instead.
    public static let dedupeRad = 0.0015

    /// Tilt: leans with the smoothed horizontal speed and settles upright at rest.
    public struct TiltSettings: Sendable {
        public var velocitySmoothingMs = 120.0
        public var tiltDegPerVelocity = 12.0
        public var maxTiltDeg = 20.0
        public var startupCalmMs = 500.0
        public var entryTeleportSpeedPxPerMs = 15.0
        public var spring = SpringConfig(stiffness: 120, damping: 8, mass: 1)
        public init() {}
    }

    /// Follow: a damped heading pulled toward the direction of travel, kept at rest.
    public struct FollowSettings: Sendable {
        public var alignRatePerPx = 0.00005
        public var speedSaturationPxPerMs = 3.0
        public var angularDampingMs = 100.0
        public var maxTurnRateDegPerMs = 0.4
        public var maxFromNeutralDeg = 135.0
        public var minTravelPx = 4.0
        /// The direction the arrow points when not rotated.
        public var neutralPullHeadingDeg = -112.5
        public var startupCalmMs = 500.0
        public var entryTeleportSpeedPxPerMs = 15.0
        public var spring = SpringConfig(stiffness: 320, damping: 28, mass: 1)
        public init() {}
    }

    public static let tilt = TiltSettings()
    public static let follow = FollowSettings()

    /// The spring the drawn rotation follows its keyframes with.
    public static func spring(for mode: CursorRotationMode) -> SpringConfig {
        mode == .directional ? follow.spring : tilt.spring
    }

    /// Keyframes for `events` (positions in recording pixels, sorted by time). `startRotationRad`
    /// continues a Follow heading from an earlier plan; nil starts from the first travel.
    public static func keyframes(_ events: [MouseEvent], config: CursorConfig, startRotationRad: Double? = nil) -> [CursorRotationKeyframe] {
        config.rotationMode == .directional
            ? followKeyframes(events, startRotationRad: startRotationRad)
            : tiltKeyframes(events, ratio: config.rotateOnXMovementRatio)
    }

    /// The angle at `t`, linear between keyframes and held past both ends.
    public static func rotation(at t: Double, in keyframes: [CursorRotationKeyframe]) -> Double {
        guard let first = keyframes.first else { return 0 }
        guard let i = floorSearch(count: keyframes.count, value: t, key: { keyframes[$0].timeMs }) else { return first.rotationRad }
        let a = keyframes[i]
        guard i + 1 < keyframes.count else { return a.rotationRad }
        let b = keyframes[i + 1]
        let span = b.timeMs - a.timeMs
        let f = span > 0 ? clamp((t - a.timeMs) / span, 0, 1) : 0
        return a.rotationRad + (b.rotationRad - a.rotationRad) * f
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Collects keyframes, holding back ones that barely change the angle.
    struct Emitter {
        var keyframes: [CursorRotationKeyframe] = []
        var lastEmittedRad = Double.nan
        var pendingHold: CursorRotationKeyframe?

        mutating func emit(_ t: Double, _ rad: Double, force: Bool = false) {
            if !force && abs(rad - lastEmittedRad) < CursorRotation.dedupeRad {
                pendingHold = CursorRotationKeyframe(timeMs: t, rotationRad: rad)
                return
            }
            if let hold = pendingHold, hold.timeMs < t { keyframes.append(hold) }
            pendingHold = nil
            if let last = keyframes.last, last.timeMs == t {
                keyframes[keyframes.count - 1].rotationRad = rad
            } else {
                keyframes.append(CursorRotationKeyframe(timeMs: t, rotationRad: rad))
            }
            lastEmittedRad = rad
        }
    }

    /// Holds the first `calmMs` at the angle reached by then.
    static func calmed(_ keyframes: [CursorRotationKeyframe], calmMs: Double) -> [CursorRotationKeyframe] {
        guard keyframes.count >= 2, calmMs > 0 else { return keyframes }
        let start = keyframes[0].timeMs
        let end = start + calmMs
        let held = rotation(at: end, in: keyframes)
        return [CursorRotationKeyframe(timeMs: start, rotationRad: held), CursorRotationKeyframe(timeMs: end, rotationRad: held)]
            + keyframes.filter { $0.timeMs > end }
    }

    /// The first move is a jump into the recording (faster than `speed` px/ms).
    static func startsWithTeleport(_ events: [MouseEvent], speed: Double) -> Bool {
        guard events.count >= 2 else { return false }
        let dt = events[1].timeMs - events[0].timeMs
        guard dt > 0 else { return false }
        return hypot(events[1].position.x - events[0].position.x, events[1].position.y - events[0].position.y) / dt > speed
    }

    /// Horizontal speed from `events[start - 1]` to the first event at least `smoothingMs` later.
    static func initialVelocityX(_ events: [MouseEvent], smoothingMs: Double, start: Int) -> Double {
        guard start >= 1, start - 1 < events.count else { return 0 }
        let origin = events[start - 1]
        var i = start
        while i < events.count {
            let dt = events[i].timeMs - origin.timeMs
            if !(dt < smoothingMs && i < events.count - 1) {
                return dt > 0 ? (events[i].position.x - origin.position.x) / dt : 0
            }
            i += 1
        }
        return 0
    }

    public static func tiltKeyframes(_ events: [MouseEvent], ratio: Double, settings s: TiltSettings = tilt) -> [CursorRotationKeyframe] {
        var out = Emitter()
        guard let first = events.first, ratio != 0 else { return out.keyframes }
        let start = startsWithTeleport(events, speed: s.entryTeleportSpeedPxPerMs) ? 2 : 1
        var velocity = initialVelocityX(events, smoothingMs: s.velocitySmoothingMs, start: start)
        func angle(_ v: Double) -> Double { radians(clamp(v * s.tiltDegPerVelocity * ratio, -s.maxTiltDeg, s.maxTiltDeg)) }
        out.emit(first.timeMs, angle(velocity), force: true)
        func advance(from t0: Double, by duration: Double, toward target: Double) {
            let steps = max(1, Int((duration / stepMs).rounded(.up)))
            let h = duration / Double(steps)
            let blend = 1 - exp(-h / s.velocitySmoothingMs)
            for k in 1...steps {
                velocity += (target - velocity) * blend
                out.emit(t0 + Double(k) * h, angle(velocity))
            }
        }
        var previous = first
        for i in 1..<max(events.count, 1) {
            let event = events[i]
            let dt = event.timeMs - previous.timeMs
            if dt > 0 {
                let target = i < start ? 0 : (event.position.x - previous.position.x) / dt
                advance(from: previous.timeMs, by: dt, toward: target)
            }
            previous = event
        }
        let tail = s.velocitySmoothingMs * 6
        advance(from: previous.timeMs, by: tail, toward: 0)
        out.emit(previous.timeMs + tail, 0, force: true)
        return calmed(out.keyframes, calmMs: s.startupCalmMs)
    }

    /// Wraps an angle into −π…π.
    static func wrapped(_ a: Double) -> Double {
        let full = Double.pi * 2
        return ((a + .pi).truncatingRemainder(dividingBy: full) + full).truncatingRemainder(dividingBy: full) - .pi
    }

    /// The heading of the first travel of at least `minTravelPx` from `events[start - 1]`.
    static func initialHeading(_ events: [MouseEvent], settings s: FollowSettings, start: Int) -> Double {
        let neutral = radians(s.neutralPullHeadingDeg)
        let maxFromNeutral = radians(s.maxFromNeutralDeg)
        guard start >= 1, start - 1 < events.count else { return 0 }
        let origin = events[start - 1]
        var i = start
        while i < events.count {
            let dx = events[i].position.x - origin.position.x
            let dy = events[i].position.y - origin.position.y
            if !(hypot(dx, dy) < s.minTravelPx) {
                return clamp(wrapped(atan2(dy, dx) - neutral), -maxFromNeutral, maxFromNeutral)
            }
            i += 1
        }
        return 0
    }

    public static func followKeyframes(_ events: [MouseEvent], settings s: FollowSettings = follow, startRotationRad: Double? = nil) -> [CursorRotationKeyframe] {
        var out = Emitter()
        guard let first = events.first else { return out.keyframes }
        let neutral = radians(s.neutralPullHeadingDeg)
        let maxFromNeutral = radians(s.maxFromNeutralDeg)
        let maxTurn = radians(s.maxTurnRateDegPerMs)
        let start = startsWithTeleport(events, speed: s.entryTeleportSpeedPxPerMs) ? 2 : 1
        var heading = startRotationRad ?? initialHeading(events, settings: s, start: start)
        var omega = 0.0
        var travelX = 0.0, travelY = 0.0, travelMs = 0.0
        out.emit(first.timeMs, heading, force: true)
        func advance(from t0: Double, by duration: Double, direction: Double?, speed: Double) {
            let steps = max(1, Int((duration / stepMs).rounded(.up)))
            let h = duration / Double(steps)
            let decay = exp(-h / s.angularDampingMs)
            for k in 1...steps {
                if let direction {
                    let error = direction - (neutral + heading)
                    omega += s.alignRatePerPx * min(speed, s.speedSaturationPxPerMs) * sin(error) * h
                }
                omega *= decay
                omega = clamp(omega, -maxTurn, maxTurn)
                heading += omega * h
                if abs(heading) > maxFromNeutral {
                    heading = clamp(heading, -maxFromNeutral, maxFromNeutral)
                    omega = 0
                }
                out.emit(t0 + Double(k) * h, heading)
            }
        }
        var previous = first
        for i in 1..<max(events.count, 1) {
            let event = events[i]
            let dt = event.timeMs - previous.timeMs
            if dt > 0 {
                if i < start {
                    advance(from: previous.timeMs, by: dt, direction: nil, speed: 0)
                    previous = event
                    continue
                }
                travelX += event.position.x - previous.position.x
                travelY += event.position.y - previous.position.y
                travelMs += dt
                let distance = hypot(travelX, travelY)
                if distance >= s.minTravelPx {
                    advance(from: previous.timeMs, by: dt, direction: atan2(travelY, travelX), speed: distance / travelMs)
                    travelX = 0
                    travelY = 0
                    travelMs = 0
                } else {
                    advance(from: previous.timeMs, by: dt, direction: nil, speed: 0)
                }
            }
            previous = event
        }
        let tail = s.angularDampingMs * 8
        advance(from: previous.timeMs, by: tail, direction: nil, speed: 0)
        out.emit(previous.timeMs + tail, heading, force: true)
        return calmed(out.keyframes, calmMs: s.startupCalmMs)
    }
}
