import Foundation
import MLX

/// Runs the two speech models of the microphone chains: `mossFormer2` (preset
/// `noise-reduction`) and `tfRestormer` (preset `podcast`), both on 48 kHz mono, on MLX.
/// Calls are serialized, each model on its own serial queue.
public enum SpeechModelRunner {
    static let mossFormer2File = "MossFormer2_SE_48K_float16"
    static let tfRestormerFile = "tf-restormer"

    static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "safetensors", subdirectory: "SpeechModels")
    }

    /// Apple silicon (mlx needs it) and both weight files bundled.
    public static var isAvailable: Bool {
        #if arch(arm64)
        return url(mossFormer2File) != nil && url(tfRestormerFile) != nil
        #else
        return false
        #endif
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mossFormer2Model: MossFormer2?
    nonisolated(unsafe) private static var tfRestormerModel: TFRestormer?

    /// `Memory.cacheLimit` is 1 GiB in both `MossFormer2.init` and `TFRestormer.init`.
    private static func prepare() throws {
        guard isAvailable else { throw SpeechModelError.unavailable }
        Memory.cacheLimit = 1 << 30
    }

    static func loadMossFormer2() throws -> (MossFormer2, Weights) {
        guard let url = url(mossFormer2File) else { throw SpeechModelError.unavailable }
        let weights = try Weights(url: url, dtype: .float16)
        return (try MossFormer2(weights: weights), weights)
    }

    static func loadTFRestormer() throws -> (TFRestormer, Weights) {
        guard let url = url(tfRestormerFile) else { throw SpeechModelError.unavailable }
        let weights = try Weights(url: url, dtype: .float16)
        return (try TFRestormer(weights: weights), weights)
    }

    /// MossFormer2_SE_48K: removes noise and room from 48 kHz mono speech; same length out.
    public static func mossFormer2(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate == 48000 else { throw SpeechModelError.unsupportedSampleRate(sampleRate) }
        lock.lock()
        defer { lock.unlock() }
        try prepare()
        if mossFormer2Model == nil { mossFormer2Model = try loadMossFormer2().0 }
        return try mossFormer2Model!.enhance(samples)
    }

    /// TF-Restormer: restores 48 kHz mono speech to full band (highs up to 17 kHz), then writes
    /// long pauses as silence with fades around speech.
    /// - `highestFrequencyHz`: the take's `highestFrequencyWithContent(within: bandEndsBelowPeakDb)`
    ///   from the first-pass `Measure`; `bandEndsBelowPeakDb` is the margin that measurement used
    ///   and is not applied again here.
    /// - `speechLevelDb`: the chain's speech level (`typicalLoudLevel` + normalize gain).
    public static func tfRestormer(
        _ samples: [Float], sampleRate: Double, bandEndsBelowPeakDb: Double, pauseBelowSpeechDb: Double,
        pauseLevelDb: ClosedRange<Double>, shortestSilenceMs: Double, keptAroundSpeechMs: Double,
        fadeMs: Double, speechLevelDb: Double, highestFrequencyHz: Double
    ) throws -> [Float] {
        guard sampleRate == 48000 else { throw SpeechModelError.unsupportedSampleRate(sampleRate) }
        lock.lock()
        defer { lock.unlock() }
        try prepare()
        if tfRestormerModel == nil { tfRestormerModel = try loadTFRestormer().0 }
        var out = try tfRestormerModel!.restore(samples, contentUpTo: highestFrequencyHz)
        let gate = PauseGate(
            speechLevelDb: speechLevelDb, pauseBelowSpeechDb: pauseBelowSpeechDb, pauseLevelDb: pauseLevelDb,
            shortestSilenceMs: shortestSilenceMs, keptAroundSpeechMs: keptAroundSpeechMs, fadeMs: fadeMs,
            sampleRate: sampleRate)
        let gains = gate.gains(measuring: samples)
        for i in out.indices { out[i] *= gains[i] }
        return out
    }
}
