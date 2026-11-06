import Foundation

/// The stretch an audio change preview repeats: from the playhead (or the changed range's start
/// when the playhead is outside it), up to 2 s and at least 0.5 s, kept inside the range.
public struct AudioPreviewLoop: Hashable, Sendable {
    /// Output rate of the preview, frames per second.
    public static let sampleRate = 48_000.0
    public static let maxDurationMs = 2000.0
    public static let minDurationMs = 500.0
    /// The preview keeps playing this long after the last change, then fades out.
    public static let holdMs = 500.0
    /// Gain ramps, in frames at `sampleRate`.
    public static let fadeInFrames = 480
    public static let fadeOutFrames = 3840
    public static let crossfadeFrames = 960

    public var startFrame: Int
    public var endFrame: Int

    public var startMs: Double { Double(startFrame) / Self.sampleRate * 1000 }
    public var endMs: Double { Double(endFrame) / Self.sampleRate * 1000 }

    /// `timeMs` is the playhead; `changedStartMs…changedEndMs` the changed range, playback ms.
    public init(timeMs: Double, changedStartMs: Double, changedEndMs: Double) {
        let start = max(changedStartMs, 0)
        let end = max(changedEndMs, start)
        var t = start <= timeMs && timeMs < end ? timeMs : start
        t = min(t, end - Self.minDurationMs)
        t = max(t, start)
        let loopEnd = max(min(t + Self.maxDurationMs, end), t + Self.minDurationMs)
        func frame(_ ms: Double) -> Int { Int((max(ms, 0) / 1000 * Self.sampleRate).rounded()) }
        startFrame = frame(t)
        endFrame = frame(loopEnd)
    }
}

/// Per-sample gains of an audio change preview: voices crossfade linearly (the newest rises,
/// the older ones fall) and the whole preview fades in, or out once its hold has passed.
public enum PreviewGainRamp {
    /// One sample later: the newest voice gains 1/`crossfadeFrames`, the others lose it.
    public static func stepVoice(_ gain: Float, isNewest: Bool) -> Float {
        let step = 1 / Float(AudioPreviewLoop.crossfadeFrames)
        let falling = gain - step
        let rising = min(step + gain, 1)
        return isNewest ? rising : (falling < 0 ? 0 : falling)
    }

    /// One sample later: up over `fadeInFrames`, or down over `fadeOutFrames` when fading out.
    public static func stepMaster(_ gain: Float, fadingOut: Bool) -> Float {
        let next = fadingOut
            ? -1 / Float(AudioPreviewLoop.fadeOutFrames) + gain
            : 1 / Float(AudioPreviewLoop.fadeInFrames) + gain
        return min(next < 0 ? 0 : next, 1)
    }

    /// The output gain of a sample: the master over the sum of the voice gains.
    public static func outputScale(master: Float, voiceGainSum: Float) -> Float {
        master / max(voiceGainSum, Float.leastNormalMagnitude)
    }
}
