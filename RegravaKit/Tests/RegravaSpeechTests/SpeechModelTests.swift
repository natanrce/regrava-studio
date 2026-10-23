import Foundation
import MLX
import Testing
@testable import RegravaSpeech

/// `swift test` does not build mlx's Metal kernels (mlx-swift README). Compile them once with
/// `build-mlx-metallib.sh` into `.build/mlx.metallib` and hand that to MLX. Xcode builds of the
/// app bundle the metallib themselves and skip this.
enum MetalLibrary {
    static let ready: Bool = {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let package = tests.deletingLastPathComponent().deletingLastPathComponent()
        let lib = package.appendingPathComponent(".build/mlx.metallib")
        if !FileManager.default.fileExists(atPath: lib.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [tests.appendingPathComponent("build-mlx-metallib.sh").path, package.path, lib.path]
            try? p.run()
            p.waitUntilExit()
        }
        guard FileManager.default.fileExists(atPath: lib.path) else { return false }
        GPU.metallib = lib
        return true
    }()
}

/// A synthetic voiced signal: a glottal pulse train (f0 110-140 Hz) through three formant
/// resonators, with a 4 Hz syllable envelope and short pauses.
func voiced(seconds: Double, rate: Double = 48000, bandLimit: Double? = nil) -> [Float] {
    let n = Int(seconds * rate)
    var source = [Double](repeating: 0, count: n)
    var phase = 0.0
    for i in 0 ..< n {
        let t = Double(i) / rate
        let f0 = 125 + 15 * sin(2 * .pi * 0.7 * t)
        if let limit = bandLimit {
            var s = 0.0
            var h = 1
            while Double(h) * f0 < limit { s += sin(Double(h) * phase) / Double(h).squareRoot(); h += 1 }
            source[i] = s * 0.05
        } else {
            source[i] = phase.truncatingRemainder(dividingBy: 2 * .pi) < 2 * .pi * f0 / rate ? 1 : 0
        }
        phase += 2 * .pi * f0 / rate
    }
    var y = source
    for (f, bw) in [(700.0, 110.0), (1200.0, 120.0), (2600.0, 160.0)] {
        let r = exp(-.pi * bw / rate), c = 2 * r * cos(2 * .pi * f / rate)
        var y1 = 0.0, y2 = 0.0
        var out = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let v = (1 - r) * y[i] + c * y1 - r * r * y2
            out[i] = v; y2 = y1; y1 = v
        }
        y = zip(y, out).map { $0 * 0.2 + $1 }
    }
    let peak = y.map(abs).max() ?? 1
    return (0 ..< n).map { i in
        let t = Double(i) / rate
        let syllable = max(0, sin(2 * .pi * 2 * t))  // 4 voiced bursts per second
        return Float(0.5 * y[i] / peak * syllable)
    }
}

func noise(count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0 ..< count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let a = Double(state >> 11) / Double(1 << 53)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let b = Double(state >> 11) / Double(1 << 53)
        return Float((-2 * log(max(a, 1e-12))).squareRoot() * cos(2 * .pi * b))
    }
}

func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }

func snr(_ clean: [Float], _ test: [Float]) -> Double {
    10 * log10(energy(clean) / energy(zip(clean, test).map { $1 - $0 }))
}

/// Energy of `x` above `hz` (whole-signal DFT via vDSP-free MLX rfft).
func energyAbove(_ x: [Float], hz: Double, rate: Double = 48000) -> Double {
    let spectrum = abs(rfft(MLXArray(x))).square()
    let first = Int(hz / rate * Double(x.count))
    return Double(spectrum[first...].sum().item(Float.self))
}

@Suite(.serialized, .enabled(if: SpeechModelRunner.isAvailable && MetalLibrary.ready))
struct SpeechModelTests {
    @Test func mossFormer2WeightsAreAllConsumed() throws {
        let (_, weights) = try SpeechModelRunner.loadMossFormer2()
        #expect(weights.names.count == 906)
        #expect(weights.unused.isEmpty, "unused: \(weights.unused.sorted())")
    }

    @Test func tfRestormerWeightsAreAllConsumed() throws {
        let (_, weights) = try SpeechModelRunner.loadTFRestormer()
        #expect(weights.names.count == 305)
        #expect(weights.unused.isEmpty, "unused: \(weights.unused.sorted())")
    }

    @Test func tfRestormerBins() {
        #expect(TFRestormer.bins(contentUpTo: 3000) == (161, 684))
        #expect(TFRestormer.bins(contentUpTo: 8000) == (330, 684))
        #expect(TFRestormer.bins(contentUpTo: 24000) == (961, 961))
    }

    @Test func tfRestormerStftIsPerfectReconstruction() throws {
        let (model, _) = try SpeechModelRunner.loadTFRestormer()
        // Sines away from DC and Nyquist, where the 1.0 bin weights of `synthesize` apply.
        let x: [Float] = (0 ..< 960 * 50).map { (i: Int) -> Float in
            let t = Double(i)
            return Float(0.3 * sin(t * 0.0731) + 0.2 * sin(t * 1.913 + 1))
        }
        let frames = 49
        let spectrum = model.analyze(x, frames: frames)
        let y = model.synthesize(re: spectrum.realPart(), im: spectrum.imaginaryPart(), frames: frames)
        let inner = 960 ..< (960 * 49)
        let err = inner.map { abs(x[$0] - y[$0]) }.max() ?? 1
        #expect(err < 1e-3)
    }

    @Test func mossFormer2RemovesNoise() throws {
        let clean = voiced(seconds: 14)
        let n = noise(count: clean.count, seed: 7)
        let noiseGain = Float((energy(clean) / energy(n) / pow(10, 0.5)).squareRoot())  // 5 dB SNR
        let noisy = zip(clean, n).map { $0 + noiseGain * $1 }
        let start = Date()
        let out = try SpeechModelRunner.mossFormer2(noisy, sampleRate: 48000)
        let elapsed = Date().timeIntervalSince(start)
        print("MossFormer2: \(14 / elapsed) s of audio per second (incl. first load)")
        #expect(out.count == noisy.count)
        #expect(out.allSatisfy { $0.isFinite })
        let before = snr(clean, noisy), after = snr(clean, out)
        print("MossFormer2 SNR \(before) dB -> \(after) dB")
        #expect(after > before + 3)
    }

    @Test func tfRestormerExtendsTheBand() throws {
        let input = voiced(seconds: 4, bandLimit: 4000)
        let start = Date()
        let out = try SpeechModelRunner.tfRestormer(
            input, sampleRate: 48000, bandEndsBelowPeakDb: 60, pauseBelowSpeechDb: 30, pauseLevelDb: -75 ... -45,
            shortestSilenceMs: 400, keptAroundSpeechMs: 300, fadeMs: 10, speechLevelDb: -12, highestFrequencyHz: 4000)
        let elapsed = Date().timeIntervalSince(start)
        print("TF-Restormer: \(4 / elapsed) s of audio per second (incl. first load)")
        #expect(out.count == input.count)
        #expect(out.allSatisfy { $0.isFinite })
        let above = energyAbove(out, hz: 4500), total = energy(out) * Double(out.count)
        print("TF-Restormer energy above 4.5 kHz: in \(energyAbove(input, hz: 4500) / (energy(input) * Double(input.count))) out \(above / total)")
        #expect(above > 10 * energyAbove(input, hz: 4500))
        #expect(above / total > 1e-5)
    }

    @Test func tfRestormerKeepsLengthAcrossSegments() throws {
        let input = voiced(seconds: 16.3, bandLimit: 4000)  // two 750-frame segments, crossfaded
        let out = try SpeechModelRunner.tfRestormer(
            input, sampleRate: 48000, bandEndsBelowPeakDb: 60, pauseBelowSpeechDb: 30, pauseLevelDb: -75 ... -45,
            shortestSilenceMs: 400, keptAroundSpeechMs: 300, fadeMs: 10, speechLevelDb: -12, highestFrequencyHz: 4000)
        #expect(out.count == input.count)
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func pauseGateSilencesLongPausesOnly() {
        let rate = 48000
        var x = [Float](repeating: 0, count: rate * 3)
        for i in 0 ..< rate { x[i] = 0.3 * sin(Float(i) * 0.05) }  // 1 s speech
        for i in (2 * rate) ..< (3 * rate) { x[i] = 0.3 * sin(Float(i) * 0.05) }  // 1 s pause, 1 s speech
        let gate = PauseGate(speechLevelDb: -13, pauseBelowSpeechDb: 30, pauseLevelDb: -75 ... -45,
                             shortestSilenceMs: 400, keptAroundSpeechMs: 300, fadeMs: 10)
        let g = gate.gains(measuring: x)
        #expect(g[rate / 2] == 1)
        #expect(g[rate + rate / 2] == 0)  // the middle of the pause
        #expect(g[rate + rate / 10] == 1)  // within 300 ms of speech
        #expect(g[2 * rate + rate / 2] == 1)
    }
}
