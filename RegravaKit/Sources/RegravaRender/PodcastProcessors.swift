import Accelerate
import Foundation
import RegravaCore

// The STFT steps of the Podcast chain.

/// `Stft`: hop = frame/4, periodic sqrt-Hann analysis and synthesis, weighted overlap-add
/// with unity gain.
struct Stft {
    let frame: Int
    let hop: Int
    let window: [Float]
    let rate: Double
    private let setups: Setups

    /// The forward and inverse DFT setups, destroyed with the last copy of the `Stft`.
    private final class Setups {
        let forward: vDSP_DFT_Setup
        let inverse: vDSP_DFT_Setup

        init(frame: Int) {
            forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(frame), .FORWARD)!
            inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(frame), .INVERSE)!
        }

        deinit {
            vDSP_DFT_DestroySetup(inverse)
            vDSP_DFT_DestroySetup(forward)
        }
    }

    init(frame: Int, rate: Double = MicrophoneRenderer.sampleRate) {
        self.frame = frame
        hop = frame / 4
        self.rate = rate
        window = (0..<frame).map { Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame)))) }
        setups = Setups(frame: frame)
    }

    var bins: Int { frame / 2 + 1 }
    func frequency(_ k: Int) -> Double { Double(k) * rate / Double(frame) }

    /// `bins(in:)`: `[ceil(lo·N/fs), ceil(hi·N/fs))`.
    func bins(in hz: ClosedRange<Double>) -> Range<Int> {
        let lo = Int(ceil(max(0, hz.lowerBound * Double(frame) / rate)))
        let hi = Int(ceil(max(0, hz.upperBound * Double(frame) / rate)))
        return min(lo, bins)..<min(max(hi, lo), bins)
    }

    /// `taper`: 0 outside the band, ramping to 1 over `octaves` inside each edge (log frequency).
    func taper(_ hz: ClosedRange<Double>, octaves: Double) -> [Float] {
        (0..<bins).map { k in
            let f = max(frequency(k), 1)
            guard f >= hz.lowerBound && f <= hz.upperBound else { return 0 }
            let w = min((log2(f) - log2(hz.lowerBound)) / octaves, (log2(hz.upperBound) - log2(f)) / octaves)
            return Float(clamp(w, 0, 1))
        }
    }

    /// `level(power:)` of a bin range, dB.
    func level(_ power: [Float], _ range: Range<Int>) -> Double {
        guard !range.isEmpty else { return -200 }
        var sum: Float = 0
        for k in range { sum += power[k] }
        return 10 * log10(4 * Double(sum) / Double(range.count) / Double(frame * frame) + 1e-20)
    }

    /// Scratch buffers of the packed real DFT.
    private struct Scratch {
        var inRe, inIm, outRe, outIm: [Float]
        init(half: Int) {
            inRe = [Float](repeating: 0, count: half)
            inIm = inRe
            outRe = inRe
            outIm = inRe
        }
    }

    /// One channel zero-padded for framing: `frame − hop` before, a frame after.
    private func padded(_ x: [Float]) -> [Float] {
        [Float](repeating: 0, count: frame - hop) + x + [Float](repeating: 0, count: frame)
    }

    /// Frames of a channel of `length` samples, in the padded signal.
    private func frameStarts(length: Int, padded: Int) -> StrideTo<Int> {
        let lead = frame - hop
        // Frames start every hop while a whole frame fits and the start is inside the signal.
        return stride(from: 0, to: max(0, min(padded - frame + 1, lead + length)), by: hop)
    }

    /// The spectrum of the frame at `start` into `re`/`im` (`bins` values each; the imaginary
    /// parts of bin 0 and Nyquist are left untouched).
    private func analyzeFrame(_ padded: [Float], at start: Int, re: inout [Float], im: inout [Float], scratch: inout Scratch) {
        let half = frame / 2
        // Even/odd split for the packed real DFT.
        for n in 0..<half {
            scratch.inRe[n] = padded[start + 2 * n] * window[2 * n]
            scratch.inIm[n] = padded[start + 2 * n + 1] * window[2 * n + 1]
        }
        vDSP_DFT_Execute(setups.forward, scratch.inRe, scratch.inIm, &scratch.outRe, &scratch.outIm)
        // Unpack: bin 0 and Nyquist share the first slot; values come out doubled.
        re[0] = scratch.outRe[0] / 2
        re[half] = scratch.outIm[0] / 2
        for k in 1..<half {
            re[k] = scratch.outRe[k] / 2
            im[k] = scratch.outIm[k] / 2
        }
    }

    /// Overlap-adds the frame `index` back into `out` (padded like the input).
    private func synthesizeFrame(re: [Float], im: [Float], index: Int, into out: inout [Float], scratch: inout Scratch) {
        let half = frame / 2
        // The inverse real DFT gives 2N·x, and sqrt-Hann analysis × synthesis at 75% overlap sums to 2.
        let scale = 1 / (Float(frame) * 4)
        scratch.inRe[0] = re[0] * 2
        scratch.inIm[0] = re[half] * 2
        for k in 1..<half {
            scratch.inRe[k] = re[k] * 2
            scratch.inIm[k] = im[k] * 2
        }
        vDSP_DFT_Execute(setups.inverse, scratch.inRe, scratch.inIm, &scratch.outRe, &scratch.outIm)
        let start = index * hop
        for n in 0..<half where start + 2 * n + 1 < out.count {
            out[start + 2 * n] += scratch.outRe[n] * scale * window[2 * n]
            out[start + 2 * n + 1] += scratch.outIm[n] * scale * window[2 * n + 1]
        }
    }

    /// Spectra of one channel, frame by frame (zero-padded edges, lead-in frame − hop).
    func analyze(_ x: [Float]) -> [(re: [Float], im: [Float])] {
        let signal = padded(x)
        var scratch = Scratch(half: frame / 2)
        return frameStarts(length: x.count, padded: signal.count).map { start in
            var re = [Float](repeating: 0, count: bins), im = [Float](repeating: 0, count: bins)
            analyzeFrame(signal, at: start, re: &re, im: &im, scratch: &scratch)
            return (re, im)
        }
    }

    /// Weighted overlap-add back to `length` samples.
    func synthesize(_ frames: [(re: [Float], im: [Float])], length: Int) -> [Float] {
        let lead = frame - hop
        var out = [Float](repeating: 0, count: lead + length + frame)
        var scratch = Scratch(half: frame / 2)
        for (index, spectrum) in frames.enumerated() {
            synthesizeFrame(re: spectrum.re, im: spectrum.im, index: index, into: &out, scratch: &scratch)
        }
        return Array(out[lead..<(lead + length)])
    }

    /// `Equalizer.process`: the same real gain on both channels per bin, from their average power.
    /// Frame by frame: each is analysed, scaled and added back before the next.
    func equalize(_ audio: MicrophoneRenderer.Stereo, gains: ([Float]) -> [Float]) -> MicrophoneRenderer.Stereo {
        let lead = frame - hop, length = audio.count
        let left = padded(audio.left), right = padded(audio.right)
        var outLeft = [Float](repeating: 0, count: lead + length + frame), outRight = outLeft
        var reL = [Float](repeating: 0, count: bins), imL = reL, reR = reL, imR = reL, power = reL
        var scratch = Scratch(half: frame / 2)
        for (index, start) in frameStarts(length: length, padded: left.count).enumerated() {
            analyzeFrame(left, at: start, re: &reL, im: &imL, scratch: &scratch)
            analyzeFrame(right, at: start, re: &reR, im: &imR, scratch: &scratch)
            for k in 0..<bins {
                power[k] = 0.5 * (reL[k] * reL[k] + imL[k] * imL[k] + reR[k] * reR[k] + imR[k] * imR[k])
            }
            let g = gains(power)
            for k in 0..<bins {
                reL[k] *= g[k]; imL[k] *= g[k]
                reR[k] *= g[k]; imR[k] *= g[k]
            }
            synthesizeFrame(re: reL, im: imL, index: index, into: &outLeft, scratch: &scratch)
            synthesizeFrame(re: reR, im: imR, index: index, into: &outRight, scratch: &scratch)
        }
        return MicrophoneRenderer.Stereo(left: Array(outLeft[lead..<(lead + length)]), right: Array(outRight[lead..<(lead + length)]))
    }
}

enum MatchEq {
    /// `Equalizer<FixedResponse>`: the take's loud-block third-octave spectrum moved onto
    /// `target`, each band by at most `correctionDb`, smoothed over bands, 0 dB at 1 kHz.
    static func process(_ audio: MicrophoneRenderer.Stereo, measuredBands: [Double], target: [Double], correctionDb: ClosedRange<Double>) -> MicrophoneRenderer.Stereo {
        guard measuredBands.count == 25, target.count == 25 else { return audio }
        var c = (0..<25).map { clamp(target[$0] - measuredBands[$0], correctionDb.lowerBound, correctionDb.upperBound) }
        c[0] = c[1]
        c[24] = c[23]
        let kernel = (-4...4).map { exp(-Double($0 * $0) / 2) }
        let norm = kernel.reduce(0, +)
        let s: [Double] = (0..<25).map { i in
            var sum = 0.0
            for (o, w) in zip(-4...4, kernel) {
                var j = i + o
                if j < 0 { j = -j - 1 } else if j >= 25 { j = 49 - j }
                sum += w * c[j]
            }
            return sum / norm
        }
        let stft = Stft(frame: 4096)
        var gains: [Float] = (0..<stft.bins).map { k in
            let p = clamp(3 * log2(max(stft.frequency(k), 20) / 1000) + 12, 0, 24)
            let i = min(Int(floor(p)), 23)
            let v = s[i] + (p - Double(i)) * (s[i + 1] - s[i])
            return Float(pow(10, (v - s[12]) / 20))
        }
        gains[0] = gains[1]
        return stft.equalize(audio) { _ in gains }
    }
}

enum DynamicEq {
    /// `Equalizer<DynamicResponse>`: cuts `cutHz` while the detector band's energy sticks out
    /// over the reference's by more than `allowedDb` (de-esser, anti-mud).
    static func process(_ audio: MicrophoneRenderer.Stereo, frame: Int, detectorHz: ClosedRange<Double>, referenceHz: ClosedRange<Double>?, allowedDb: Double, ratio: Double, maxCutDb: Double, cutHz: ClosedRange<Double>, taperOctaves: Double, attackMs: Double, releaseMs: Double) -> MicrophoneRenderer.Stereo {
        let stft = Stft(frame: frame)
        let detector = stft.bins(in: detectorHz)
        let reference = referenceHz.map { stft.bins(in: $0) } ?? 0..<stft.bins
        let taper = stft.taper(cutHz, octaves: taperOctaves)
        let hopSeconds = Double(stft.hop) / stft.rate
        let attack = exp(-hopSeconds / max(attackMs / 1000, 1e-9)), release = exp(-hopSeconds / max(releaseMs / 1000, 1e-9))
        let slope = ratio.isFinite && ratio < 1e300 ? 1 - 1 / ratio : 1
        var state: Double?
        return stft.equalize(audio) { power in
            var d: Float = 0, r: Float = 0
            for k in detector { d += power[k] }
            for k in reference { r += power[k] }
            let excess = max(0, 10 * log10(Double(d) + 1e-20) - 10 * log10(Double(r) + 1e-20) - allowedDb)
            let cut = clamp(-slope * excess, -maxCutDb, 0)
            let prev = state ?? cut
            let coef = cut < prev ? attack : release
            let next = coef * prev + (1 - coef) * cut
            state = next
            return taper.map { Float(pow(10, next * Double($0) / 20)) }
        }
    }
}

/// `Sibilance` + `RestoreSibilance`: where the take had an S near speech and the chain output has
/// none, noise is written into 4–16 kHz, as loud per 1 kHz slice as the take's own S there. Some
/// field roles are inferred.
enum RestoreSibilance {
    struct Levels {
        var detector: [Double], reference: [Double], fill: [Double], slices: [[Double]]
    }

    static let detectorHz = 5000.0...10000.0, referenceHz = 300.0...3000.0, fillHz = 4000.0...16000.0
    static let overReferenceDb = 3.0, overFloorDb = 20.0, floorWindowMs = 4000.0, floorShare = 0.2
    static let lengthMs = 40.0...200.0, nearSpeechMs = 150.0, pauseBelowSpeechDb = 20.0, underRecordingDb = 12.0, fadeMs = 30.0

    static func levels(_ frames: [(re: [Float], im: [Float])], stft: Stft) -> Levels {
        let d = stft.bins(in: detectorHz), r = stft.bins(in: referenceHz), f = stft.bins(in: fillHz)
        let n = max(1, min(Int(((fillHz.upperBound - fillHz.lowerBound) / 1000).rounded()), f.count))
        let sliceBins = (0..<n).map { i in (f.lowerBound + f.count * i / n)..<(f.lowerBound + f.count * (i + 1) / n) }
        var out = Levels(detector: [], reference: [], fill: [], slices: [])
        for frame in frames {
            let power = (0..<stft.bins).map { frame.re[$0] * frame.re[$0] + frame.im[$0] * frame.im[$0] }
            out.detector.append(stft.level(power, d))
            out.reference.append(stft.level(power, r))
            out.fill.append(stft.level(power, f))
            out.slices.append(sliceBins.map { stft.level(power, $0) })
        }
        return out
    }

    static func mono(_ a: MicrophoneRenderer.Stereo) -> [Float] { zip(a.left, a.right).map { ($0 + $1) / 2 } }

    static func process(_ output: MicrophoneRenderer.Stereo, take: MicrophoneRenderer.Stereo, speechLevelDb: Double) -> MicrophoneRenderer.Stereo {
        let stft = Stft(frame: 1920)
        let takeLevels = levels(stft.analyze(mono(take)), stft: stft)
        let fps = 100.0
        // S frames of the take: over the reference and over the sliding 20th-percentile floor, in runs of 40–200 ms.
        let half = Int((floorWindowMs / 1000 * fps).rounded()) / 2
        let count = takeLevels.detector.count
        var isS = [Bool](repeating: false, count: count)
        // The detector levels of frames i − half … i + half, kept sorted as the window slides.
        var window: [Double] = []
        window.reserveCapacity(2 * half + 1)
        func upperBound(_ v: Double) -> Int {
            var lo = 0, hi = window.count
            while lo < hi { let mid = (lo + hi) / 2; if window[mid] > v { hi = mid } else { lo = mid + 1 } }
            return lo
        }
        if count > 0 { for j in 0...min(count - 1, half) { window.insert(takeLevels.detector[j], at: upperBound(takeLevels.detector[j])) } }
        for i in 0..<count {
            if i > 0 {
                if i + half <= count - 1 { window.insert(takeLevels.detector[i + half], at: upperBound(takeLevels.detector[i + half])) }
                if i - 1 - half >= 0 { window.remove(at: upperBound(takeLevels.detector[i - 1 - half]) - 1) }
            }
            let floor = window[min(window.count - 1, Int(floorShare * Double(window.count)))]
            isS[i] = takeLevels.detector[i] > takeLevels.reference[i] + overReferenceDb && takeLevels.detector[i] > floor + overFloorDb
        }
        let minRun = Int((lengthMs.lowerBound / 1000 * fps).rounded()), maxRun = Int((lengthMs.upperBound / 1000 * fps).rounded())
        var kept = [Bool](repeating: false, count: count)
        var i = 0
        while i < count {
            guard isS[i] else { i += 1; continue }
            var j = i
            while j < count && isS[j] { j += 1 }
            if j - i >= minRun && j - i <= maxRun { for k in i..<j { kept[k] = true } }
            i = j
        }
        guard kept.contains(true) else { return output }

        var left = stft.analyze(output.left), right = stft.analyze(output.right)
        let outLevels = levels(zip(left, right).map { l, r in
            (zip(l.re, r.re).map { ($0 + $1) / 2 }, zip(l.im, r.im).map { ($0 + $1) / 2 })
        }, stft: stft)
        // The chain's level change between take and output (inferred).
        let gain = outLevels.reference.sorted()[outLevels.reference.count * 7 / 10] - takeLevels.reference.sorted()[takeLevels.reference.count * 7 / 10]
        let fade = Int((fadeMs / 1000 * fps).rounded()), near = Int((nearSpeechMs / 1000 * fps).rounded())
        let pause = speechLevelDb - pauseBelowSpeechDb
        let frames = min(left.count, right.count, count)
        // Prefix counts: output frames with speech, then frames needing a fill (a kept S with
        // speech within `near` frames and the output's fill band too quiet).
        var speechBefore = [Int](repeating: 0, count: frames + 1)
        for m in 0..<frames { speechBefore[m + 1] = speechBefore[m] + (outLevels.reference[m] > pause ? 1 : 0) }
        var fillsBefore = [Int](repeating: 0, count: frames + 1)
        for m in 0..<frames {
            let speechNear = speechBefore[min(frames - 1, m + near) + 1] - speechBefore[max(0, m - near)] > 0
            let needsFill = kept[m] && speechNear && outLevels.fill[m] < takeLevels.fill[m] + gain - underRecordingDb
            fillsBefore[m + 1] = fillsBefore[m] + (needsFill ? 1 : 0)
        }
        let f = stft.bins(in: fillHz)
        let n = takeLevels.slices.first?.count ?? 0
        var seed: UInt32 = 0x9E37_79B9
        for frameIndex in 0..<frames {
            let hits = fillsBefore[min(frames - 1, frameIndex + fade) + 1] - fillsBefore[max(0, frameIndex - fade)]
            guard hits > 0 else { continue }
            let wet = Float(min(1, Double(hits) / Double(fade + 1)))
            // The recorded S nearest this frame.
            guard let source = (0...fade).lazy.flatMap({ [frameIndex - $0, frameIndex + $0] }).first(where: { $0 >= 0 && $0 < count && kept[$0] }) else { continue }
            for slice in 0..<n {
                let lo = f.lowerBound + f.count * slice / n, hi = f.lowerBound + f.count * (slice + 1) / n
                let amplitude = Float(pow(10, (gain + takeLevels.slices[source][slice]) / 20) * Double(stft.frame) * 0.5 * 2)
                for k in lo..<hi {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    let phase = Float(Double(seed) / 4_294_967_296 * 2 * .pi)
                    let re = amplitude * cos(phase), im = amplitude * sin(phase)
                    left[frameIndex].re[k] = (1 - wet) * left[frameIndex].re[k] + wet * re
                    left[frameIndex].im[k] = (1 - wet) * left[frameIndex].im[k] + wet * im
                    right[frameIndex].re[k] = (1 - wet) * right[frameIndex].re[k] + wet * re
                    right[frameIndex].im[k] = (1 - wet) * right[frameIndex].im[k] + wet * im
                }
            }
        }
        return MicrophoneRenderer.Stereo(left: stft.synthesize(left, length: output.count), right: stft.synthesize(right, length: output.count))
    }
}
