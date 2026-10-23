import Foundation

/// The TF-Restormer pause gate and speech fades (`RestoreSpeech`, `Gate.frame(_:into:)`,
/// `SpeechFades`).
struct PauseGate {
    /// 20 ms frames at 48 kHz (OBS).
    static let frame = 960

    let threshold: Double
    let shortestSilenceFrames: Int
    let keptFrames: Int
    let fadeSamples: Int

    /// Threshold = `clamp(speech − pauseBelowSpeech, pauseLevel)`.
    init(speechLevelDb: Double, pauseBelowSpeechDb: Double, pauseLevelDb: ClosedRange<Double>,
         shortestSilenceMs: Double, keptAroundSpeechMs: Double, fadeMs: Double, sampleRate: Double = 48000) {
        threshold = min(max(speechLevelDb - pauseBelowSpeechDb, pauseLevelDb.lowerBound), pauseLevelDb.upperBound)
        let frameMs = 1000 * Double(Self.frame) / sampleRate
        shortestSilenceFrames = Int((shortestSilenceMs / frameMs).rounded(.up))
        keptFrames = Int((keptAroundSpeechMs / frameMs).rounded())
        fadeSamples = max(1, Int((fadeMs / 1000 * sampleRate).rounded()))
    }

    /// Per-frame level `10·log10(max(meanSquare, 1e-20))` (constants in `Gate.frame`).
    static func levels(_ x: [Float]) -> [Double] {
        stride(from: 0, to: x.count, by: frame).map { start in
            let end = min(start + frame, x.count)
            var sum = 0.0
            for i in start ..< end { sum += Double(x[i]) * Double(x[i]) }
            return 10 * log10(max(sum / Double(end - start), 1e-20))
        }
    }

    /// The gain per sample: 0 in silenced pauses, 1 in speech, linear fades of `fadeMs` at the edges of
    /// each run of speech. The decision is measured on the input take; silence is exact zero; the fade
    /// lies inside the kept run; a pause at the take's start or end needs `keptAroundSpeechMs` only on
    /// its speech side.
    func gains(measuring input: [Float]) -> [Float] {
        let level = Self.levels(input)
        var silent = [Bool](repeating: false, count: level.count)
        var i = 0
        while i < level.count {
            guard level[i] < threshold else { i += 1; continue }
            var j = i
            while j < level.count, level[j] < threshold { j += 1 }
            let speechBefore = i > 0, speechAfter = j < level.count
            let margins = (speechBefore ? 1 : 0) + (speechAfter ? 1 : 0)
            if j - i >= shortestSilenceFrames + margins * keptFrames {
                let a = i + (speechBefore ? keptFrames : 0), b = j - (speechAfter ? keptFrames : 0)
                for k in a ..< b { silent[k] = true }
            }
            i = j
        }
        var gain = [Float](repeating: 1, count: input.count)
        for (f, isSilent) in silent.enumerated() where isSilent {
            for s in (f * Self.frame) ..< min((f + 1) * Self.frame, input.count) { gain[s] = 0 }
        }
        // Fades: each run of speech ramps in and out over `fadeSamples` (`SpeechFades.fadeIn(_:over:)`).
        var s = 0
        while s < gain.count {
            guard gain[s] > 0 else { s += 1; continue }
            var e = s
            while e < gain.count, gain[e] > 0 { e += 1 }
            let n = min(fadeSamples, (e - s) / 2)
            if s > 0 { for k in 0 ..< n { gain[s + k] = min(gain[s + k], Float(k + 1) / Float(n + 1)) } }
            if e < gain.count { for k in 0 ..< n { gain[e - 1 - k] = min(gain[e - 1 - k], Float(k + 1) / Float(n + 1)) } }
            s = e
        }
        return gain
    }
}
