import Foundation

/// A press drawn by the click effect: how long ago it happened and where, in recording pixels.
public struct CursorClick: Hashable, Sendable {
    public var ageMs: Double
    public var position: Vec2

    public init(ageMs: Double, position: Vec2) {
        self.ageMs = ageMs
        self.position = position
    }
}

/// Timing and shape of the click effects. Lengths scale with the video width.
public enum ClickEffects {
    /// Presses looked back on.
    public static let recentWindowMs = 1000.0
    /// Presses drawn at once.
    public static let maxClicks = 3

    // Circle: a disc growing with an ease-out cubic and fading in, then out.
    public static let circleDurationMs = 450.0
    public static let circleStartRadius01 = 0.002
    public static let circleEndRadius01 = 0.03

    // Ripple: a damped wave travelling out from the click.
    public static let rippleDurationMs = 1000.0
    public static let rippleSpeed01 = 0.2
    public static let rippleDecay = 3.0
    public static let rippleFrequency = 9.4
    public static let ripplePull01 = 0.015
    public static let rippleChromaticAberration01 = 0.004
    public static let defaultPullSize01 = 0.04

    public static func visibleDurationMs(_ kind: ClickEffect.Kind) -> Double {
        kind == .ripple ? rippleDurationMs : circleDurationMs
    }

    /// How far an effect reads around a pixel, in video widths.
    public static func readReach01(_ kind: ClickEffect.Kind) -> Double {
        kind == .ripple ? ripplePull01 + rippleChromaticAberration01 * 4 : 0
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    public static func circleRadius(ageMs: Double, videoWidth: Double) -> Double {
        guard ageMs >= 0, ageMs <= circleDurationMs else { return 0 }
        let eased = 1 - pow(1 - ageMs / circleDurationMs, 3)
        return videoWidth * (circleStartRadius01 + (circleEndRadius01 - circleStartRadius01) * eased)
    }

    public static func circleFade(ageMs: Double) -> Double {
        guard ageMs >= 0, ageMs <= circleDurationMs else { return 0 }
        let p = ageMs / circleDurationMs
        return smoothstep(0, 0.15, p) * (1 - smoothstep(0.15, 0.9, p))
    }

    /// Radius of the wave front: the pull size, then 0.2 video widths per second.
    public static func rippleRadius(ageMs: Double, pullSize: Double, videoWidth: Double) -> Double {
        guard ageMs >= 0, ageMs <= rippleDurationMs else { return 0 }
        return pullSize + ageMs / recentWindowMs * videoWidth * rippleSpeed01
    }

    public static func rippleBounce(ageMs: Double) -> Double {
        guard ageMs >= 0, ageMs <= rippleDurationMs else { return 0 }
        let t = ageMs / recentWindowMs
        return exp(-t * rippleDecay) * sin(t * rippleFrequency)
    }

    /// Knobs shared by every click: the ripple's pull size in pixels.
    public static func knobs(_ effect: ClickEffect, videoWidth: Double) -> SIMD4<Double> {
        effect.type == .ripple ? SIMD4((effect.pullSize01 ?? defaultPullSize01) * videoWidth, 0, 0, 0) : .zero
    }

    /// (radius, fade or bounce, 0, 0) of a click `ageMs` old; nil when it shows nothing.
    public static func state(_ kind: ClickEffect.Kind, ageMs: Double, knobs: SIMD4<Double>, videoWidth: Double) -> SIMD4<Double>? {
        switch kind {
        case .circle:
            let fade = circleFade(ageMs: ageMs)
            return fade <= 0 ? nil : SIMD4(circleRadius(ageMs: ageMs, videoWidth: videoWidth), fade, 0, 0)
        case .ripple:
            let bounce = rippleBounce(ageMs: ageMs)
            return bounce == 0 ? nil : SIMD4(rippleRadius(ageMs: ageMs, pullSize: knobs.x, videoWidth: videoWidth), bounce, 0, 0)
        }
    }

    /// The presses at source time `t`: the last three in the past second, those still inside
    /// the effect's duration. `presses` are sorted by time.
    public static func recentClicks(at t: Double, presses: [MouseEvent], kind: ClickEffect.Kind) -> [CursorClick] {
        guard let last = MouseProcessing.lastIndex(atOrBefore: t, in: presses) else { return [] }
        var first = last
        while first > 0 && presses[first - 1].timeMs >= t - recentWindowMs { first -= 1 }
        guard presses[last].timeMs >= t - recentWindowMs else { return [] }
        let duration = visibleDurationMs(kind)
        return presses[max(first, last - maxClicks + 1)...last]
            .filter { t - $0.timeMs < duration }
            .map { CursorClick(ageMs: t - $0.timeMs, position: $0.position) }
    }
}
