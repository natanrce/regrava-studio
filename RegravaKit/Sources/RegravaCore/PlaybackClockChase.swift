import Foundation

/// How the picture follows the audio being heard: each playback tick moves the playhead by
/// `deltaMs` (elapsed × rate) plus a correction toward the audio clock.
public enum PlaybackClockChase {
    /// Part of the error made up per tick.
    public static let gain = 0.2
    /// A tick may run at most this much faster to catch up.
    public static let maxCatchUp = 0.5
    /// Errors larger than this are not chased.
    public static let maxErrorMs = 1000.0

    /// The correction for a tick of `deltaMs`, with `errorMs` the audio's time minus the
    /// picture's. A picture a whole tick ahead waits; a picture behind catches up by a fifth
    /// of the error, at most half a tick more.
    public static func correction(errorMs: Double, deltaMs: Double) -> Double {
        if deltaMs < 0 { return -correction(errorMs: -errorMs, deltaMs: -deltaMs) }
        guard deltaMs > 0, errorMs.isFinite, abs(errorMs) <= maxErrorMs else { return 0 }
        if errorMs <= -deltaMs { return -deltaMs }
        return min(max(errorMs * gain, -deltaMs), deltaMs * maxCatchUp)
    }

    /// The player rate that advances the picture by the corrected tick instead of `deltaMs`.
    public static func playerRate(rate: Double, deltaMs: Double, errorMs: Double) -> Double {
        guard deltaMs != 0 else { return rate }
        return rate * (deltaMs + correction(errorMs: errorMs, deltaMs: deltaMs)) / deltaMs
    }
}
