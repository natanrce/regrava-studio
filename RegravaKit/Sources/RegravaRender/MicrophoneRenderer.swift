@preconcurrency import AVFoundation
import Accelerate
import Foundation
import RegravaCore
import RegravaSpeech
import SoundAnalysis

/// Renders a project's microphone take through a preset's chain into an AAC 48 kHz stereo
/// copy: the file the editor plays and the export mixes instead of the take. Frames go to a
/// part file first, renamed when the render is complete.
public enum MicrophoneRenderer {
    public enum RenderError: LocalizedError {
        case noMicrophone
        case needsSpeechModels
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noMicrophone: return "The recording has no microphone track."
            case .needsSpeechModels: return "This mode runs a speech model that isn't available."
            case .failed(let message): return message
            }
        }
    }

    static let sampleRate = 48_000.0

    /// The rendered file when it exists (`done`).
    public static func readyURL(bundle: URL, preset: MicrophoneAudioPreset) -> URL? {
        let url = ProjectStore.audioRenderURL(bundle: bundle, preset: preset)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `bestReadyPath`: the preset's render, else the Standard render, else nil (the take).
    public static func bestReadyURL(bundle: URL, preset: MicrophoneAudioPreset) -> URL? {
        readyURL(bundle: bundle, preset: preset) ?? (preset == .voice ? nil : readyURL(bundle: bundle, preset: .voice))
    }

    /// Renders `preset` for the microphone track of `recording`; `progress` gets 0…1.
    public static func render(recording: URL, microphoneTrackIndex: Int, preset: MicrophoneAudioPreset, bundle: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let output = ProjectStore.audioRenderURL(bundle: bundle, preset: preset)
        if FileManager.default.fileExists(atPath: output.path) { return }
        var stages = preset.chain
        if stages.contains(where: \.needsSpeechModels), !SpeechModels.isAvailable { throw RenderError.needsSpeechModels }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var audio = try await read(recording, trackIndex: microphoneTrackIndex)
        progress(0.1)
        // Resampling happened on reading (48 kHz).
        stages.removeAll { if case .resample = $0 { return true } else { return false } }
        // One measure of the take serves every step; only `normalize` moves the speech level.
        let measure = Measure(audio)
        let take = audio
        guard var speech = measure.typicalLoudLevelDb else { throw RenderError.failed("The microphone has no speech level: nothing was measured.") }
        var index = 0
        while index < stages.count {
            try Task.checkCancellation()
            // Neighbouring Apple units render through one engine.
            if case .audioUnit = stages[index] {
                var units: [AudioProcessor] = []
                while index < stages.count, case .audioUnit = stages[index] { units.append(stages[index]); index += 1 }
                audio = try AppleUnits.render(audio, units: units)
            } else {
                audio = try await apply(stages[index], to: audio, take: take, measure: measure, speech: &speech)
                index += 1
            }
            progress(0.1 + 0.8 * Double(index) / Double(stages.count))
        }
        // The part file keeps the .m4a extension, which decides the container.
        let part = output.deletingPathExtension().appendingPathExtension("part.m4a")
        try? FileManager.default.removeItem(at: part)
        try await write(audio, to: part)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: part, to: output)
        progress(1)
    }

    private static func apply(_ stage: AudioProcessor, to audio: Stereo, take: Stereo, measure: Measure, speech: inout Double) async throws -> Stereo {
        switch stage {
        case .resample, .audioUnit:
            return audio
        case let .normalize(peakDb, silentChannelBelowDb):
            let (out, gain) = ChannelFix.normalize(audio, measure: measure, peakDb: peakDb, silentChannelBelowDb: silentChannelBelowDb)
            speech += 20 * log10(Double(gain) + 1e-20)
            return out
        case let .leveler(targetDb, holdBelowSpeechDb, floorDb, gainRangeDb, windowMs, lookMs, fallMs, riseMs):
            return Leveler.process(audio, speechLevelDb: speech, targetDb: targetDb, holdBelowSpeechDb: holdBelowSpeechDb, floorDb: floorDb, gainRangeDb: gainRangeDb, windowMs: windowMs, lookMs: lookMs, fallMs: fallMs, riseMs: riseMs)
        case let .keep(sounds, fadeMs, pauseDb):
            let ranges = try await Keep.keptRanges(audio, sounds: sounds)
            return Keep.apply(audio, kept: ranges, fadeMs: fadeMs ?? 10, pauseDb: pauseDb)
        case .mossFormer2:
            // The models take the mono mix; their output goes to both channels.
            let out = try SpeechModelRunner.mossFormer2(RestoreSibilance.mono(audio), sampleRate: sampleRate)
            return Stereo(left: out, right: out)
        case let .tfRestormer(bandEndsBelowPeakDb, pauseBelowSpeechDb, pauseLevelDb, shortestSilenceMs, keptAroundSpeechMs, fadeMs):
            // "The model sees the take up to where its spectrum falls `bandEndsBelowPeakDb` under its peak."
            guard let highest = measure.highestFrequencyWithContent(withinDb: bandEndsBelowPeakDb) else {
                throw RenderError.failed("The microphone has nothing to restore: no frequency rises above the noise floor.")
            }
            let out = try SpeechModelRunner.tfRestormer(
                RestoreSibilance.mono(audio), sampleRate: sampleRate, bandEndsBelowPeakDb: bandEndsBelowPeakDb,
                pauseBelowSpeechDb: pauseBelowSpeechDb, pauseLevelDb: pauseLevelDb, shortestSilenceMs: shortestSilenceMs,
                keptAroundSpeechMs: keptAroundSpeechMs, fadeMs: fadeMs, speechLevelDb: speech, highestFrequencyHz: highest
            )
            return Stereo(left: out, right: out)
        case let .matchEq(target, correctionDb):
            // From the take's own spectrum, before any step (`measure.bandLevels`).
            guard let bands = measure.bandLevels else { return audio }
            return MatchEq.process(audio, measuredBands: bands, target: target, correctionDb: correctionDb)
        case let .dynamicEq(frame, detectorHz, referenceHz, allowedDb, ratio, maxCutDb, cutHz, taperOctaves, attackMs, releaseMs):
            return DynamicEq.process(audio, frame: frame, detectorHz: detectorHz, referenceHz: referenceHz, allowedDb: allowedDb, ratio: ratio, maxCutDb: maxCutDb, cutHz: cutHz, taperOctaves: taperOctaves, attackMs: attackMs, releaseMs: releaseMs)
        case .restoreSibilance:
            return RestoreSibilance.process(audio, take: take, speechLevelDb: speech)
        }
    }

    // MARK: Reading and writing

    struct Stereo {
        var left: [Float]
        var right: [Float]
        var count: Int { left.count }
    }

    /// The microphone track as 48 kHz float stereo (mono is duplicated).
    static func read(_ url: URL, trackIndex: Int) async throws -> Stereo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(trackIndex) else { throw RenderError.noMicrophone }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw RenderError.failed(reader.error?.localizedDescription ?? "Could not read the microphone.") }
        var left: [Float] = [], right: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let frames = data.count / 2
            left.reserveCapacity(left.count + frames)
            right.reserveCapacity(right.count + frames)
            for i in 0..<frames {
                left.append(data[2 * i])
                right.append(data[2 * i + 1])
            }
        }
        if reader.status == .failed { throw RenderError.failed(reader.error?.localizedDescription ?? "Could not read the microphone.") }
        return Stereo(left: left, right: right)
    }

    /// AAC 48 kHz stereo.
    static func write(_ audio: Stereo, to url: URL) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var start = 0
        while start < audio.count {
            let n = min(chunk, audio.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            audio.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: n) }
            audio.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress! + start, count: n) }
            try file.write(from: buffer)
            start += n
        }
    }
}

/// The speech-model steps run on MLX (Apple silicon, weights bundled): `RegravaSpeech`.
public enum SpeechModels {
    public static var isAvailable: Bool { SpeechModelRunner.isAvailable }
}

// MARK: - Measure, normalize

/// The first pass over the take (`Measure`): the mono mix in 4096-sample blocks every 2048, each
/// block's level in a 1 dB histogram from −75 dB (silence in the bottom bin); peak and
/// per-channel RMS of the whole take.
struct Measure {
    static let quietest = -75.0
    static let loudAbove = 0.4

    var rows: [Int]
    var peak: Float
    var channelRMS: (Double, Double)
    /// Power per 1 dB row in the 25 third-octave bands (for `bandLevels`).
    var rowBands: [[Double]]
    /// Power per bin over every block (for `highestFrequencyWithContent`).
    var totalSpectrum: [Double]

    init(_ audio: MicrophoneRenderer.Stereo) {
        rows = [Int](repeating: 0, count: Int(-Self.quietest) + 1)
        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(audio.left, 1, &pl, vDSP_Length(audio.count))
        vDSP_maxmgv(audio.right, 1, &pr, vDSP_Length(audio.count))
        peak = max(pl, pr)
        var sl: Float = 0, sr: Float = 0
        vDSP_svesq(audio.left, 1, &sl, vDSP_Length(audio.count))
        vDSP_svesq(audio.right, 1, &sr, vDSP_Length(audio.count))
        let n = Double(max(audio.count, 1))
        channelRMS = (sqrt(Double(sl) / n), sqrt(Double(sr) / n))
        var mono = [Float](repeating: 0, count: audio.count)
        vDSP_vadd(audio.left, 1, audio.right, 1, &mono, 1, vDSP_Length(audio.count))
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(audio.count))
        rowBands = [[Double]](repeating: [Double](repeating: 0, count: 25), count: rows.count)
        totalSpectrum = [Double](repeating: 0, count: 2049)
        // Symmetric Hann over 4096 and each bin's third-octave band `round(3·log2(f/1000)) + 12`.
        let window = (0..<4096).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 4095)) }
        let bandOfBin: [Int] = (0...2048).map { k in
            let f = max(Double(k) * MicrophoneRenderer.sampleRate / 4096, 1)
            let b = (3 * log2(f / 1000)).rounded(.toNearestOrAwayFromZero) + 12
            return b >= 0 && b <= 24 ? Int(b) : -1
        }
        let setup = vDSP_DFT_zrop_CreateSetup(nil, 4096, .FORWARD)!
        defer { vDSP_DFT_DestroySetup(setup) }
        var inRe = [Float](repeating: 0, count: 2048), inIm = [Float](repeating: 0, count: 2048)
        var outRe = [Float](repeating: 0, count: 2048), outIm = [Float](repeating: 0, count: 2048)
        var start = 0
        while start + 4096 <= mono.count {
            var sum: Float = 0
            mono.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &sum, 4096) }
            let db = 10 * log10(Double(sum) / 4096 + 1e-20)
            let row = Int(clamp(db - Self.quietest, 0, Double(rows.count - 1)))
            rows[row] += 1
            for n in 0..<2048 {
                inRe[n] = mono[start + 2 * n] * window[2 * n]
                inIm[n] = mono[start + 2 * n + 1] * window[2 * n + 1]
            }
            vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
            for k in 0...2048 {
                let re = k == 0 ? outRe[0] : k == 2048 ? outIm[0] : outRe[k]
                let im = k == 0 || k == 2048 ? 0 : outIm[k]
                let p = Double(re * re + im * im) / 4
                totalSpectrum[k] += p
                if bandOfBin[k] >= 0 { rowBands[row][bandOfBin[k]] += p }
            }
            start += 2048
        }
    }

    /// `bandLevels`: the loudest ~60% of blocks' spectrum in 25 third-octave bands, dB re 1 kHz.
    var bandLevels: [Double]? {
        guard let r = percentileRow(Self.loudAbove) else { return nil }
        let start = rows[(r + 1)...].contains { $0 > 0 } ? r + 1 : r
        var p = [Double](repeating: 0, count: 25)
        for row in start..<rows.count { for i in 0..<25 { p[i] += rowBands[row][i] } }
        let ref = 10 * log10(p[12] + 1e-20)
        return p.map { 10 * log10($0 + 1e-20) - ref }
    }

    /// `highestFrequencyWithContent(within:)`: the highest bin whose total power is within `dB` of the peak bin.
    func highestFrequencyWithContent(withinDb dB: Double) -> Double? {
        guard let peak = totalSpectrum.max(), peak > 0 else { return nil }
        let threshold = peak * pow(10, -dB / 10)
        guard let k = totalSpectrum.lastIndex(where: { $0 > threshold }) else { return nil }
        return Double(k) * MicrophoneRenderer.sampleRate / 4096
    }

    /// `percentileRow(p)`: the first row whose cumulative count exceeds `p` of the total.
    func percentileRow(_ p: Double) -> Int? {
        let total = rows.reduce(0, +)
        guard total > 0 else { return nil }
        var cumulative = 0
        for (i, count) in rows.enumerated() {
            cumulative += count
            if Double(cumulative) > p * Double(total) { return i }
        }
        return rows.count - 1
    }

    /// `typicalLoudLevel`: the 70th-percentile block level, the lower edge of its 1 dB bin.
    var typicalLoudLevelDb: Double? {
        percentileRow(Self.loudAbove + (1 - Self.loudAbove) * 0.5).map { Self.quietest + Double($0) }
    }
}

enum ChannelFix {
    /// `Normalize`: gain = 10^(peakDb/20) ÷ the take's sample peak; a channel whose whole-take RMS is
    /// `silentChannelBelowDb` under the other becomes a copy of it. Returns the gain.
    static func normalize(_ audio: MicrophoneRenderer.Stereo, measure: Measure, peakDb: Double?, silentChannelBelowDb: Double) -> (MicrophoneRenderer.Stereo, gain: Float) {
        var out = audio
        var gain: Float = 1
        if let peakDb, measure.peak > 0 { gain = Float(pow(10, peakDb / 20)) / measure.peak }
        if gain != 1 {
            vDSP_vsmul(out.left, 1, &gain, &out.left, 1, vDSP_Length(out.count))
            vDSP_vsmul(out.right, 1, &gain, &out.right, 1, vDSP_Length(out.count))
        }
        let t = pow(10, silentChannelBelowDb / 20)
        let (l, r) = measure.channelRMS
        if t * l < r && t * r >= l { out.left = out.right } else if t * l >= r && t * r < l { out.right = out.left }
        return (out, gain)
    }

    static func normalize(_ audio: MicrophoneRenderer.Stereo, peakDb: Double?, silentChannelBelowDb: Double) -> MicrophoneRenderer.Stereo {
        normalize(audio, measure: Measure(audio), peakDb: peakDb, silentChannelBelowDb: silentChannelBelowDb).0
    }
}

// MARK: - Leveler

/// `Leveler`: "Brings speech to `targetDb` over seconds. Holds still in pauses so noise never comes
/// up." 10 ms hops; the gain freezes while the look-ahead hops are under max(speech −
/// holdBelowSpeech, floor), else follows target − the centred window's level through a one-pole
/// (fall going down, rise going up) and ramps linearly across each hop.
enum Leveler {
    static func process(_ audio: MicrophoneRenderer.Stereo, speechLevelDb: Double, targetDb: Double, holdBelowSpeechDb: Double, floorDb: Double, gainRangeDb: ClosedRange<Double>, windowMs: Double, lookMs: Double, fallMs: Double, riseMs: Double) -> MicrophoneRenderer.Stereo {
        let stride = 480
        let n = audio.count
        guard n > 0 else { return audio }
        func hopCount(_ ms: Double) -> Int { Int((((ms / 1000) * 48_000).rounded() / Double(stride)).rounded()) }
        let half = hopCount(windowMs) / 2, lookHops = hopCount(lookMs)
        let holdThreshold = max(speechLevelDb - holdBelowSpeechDb, floorDb)
        let fallCoef = exp(-0.01 / max(fallMs / 1000, 1e-9)), riseCoef = exp(-0.01 / max(riseMs / 1000, 1e-9))
        let hops = (n + stride - 1) / stride
        var power = [Double](repeating: 0, count: hops)
        for h in 0..<hops {
            let s0 = h * stride, e0 = min(s0 + stride, n)
            var sum = 0.0
            for i in s0..<e0 { sum += Double(audio.left[i] * audio.left[i] + audio.right[i] * audio.right[i]) * 0.5 }
            power[h] = sum / Double(stride)
        }
        var prefix = [Double](repeating: 0, count: hops + 1)
        for h in 0..<hops { prefix[h + 1] = prefix[h] + power[h] }
        func level(_ lo: Int, _ hi: Int) -> Double {
            let a = max(0, lo), b = min(hops, hi)
            guard b > a else { return -200 }
            return 10 * log10((prefix[b] - prefix[a]) / Double(b - a) + 1e-20)
        }
        var smoothed: Double?
        var lastApplied: Double?
        var out = audio
        for counter in 0..<hops {
            let i = counter + 1
            var gainLinear: Double
            if level(i, i + lookHops) < holdThreshold {
                gainLinear = smoothed.map { pow(10, $0 / 20) } ?? 1
            } else {
                // The centred window reaches only as far ahead as is buffered (lookHops + 1).
                let L = level(i - half, min(i + half + 1, counter + lookHops + 2))
                let g = clamp(targetDb - L, gainRangeDb.lowerBound, gainRangeDb.upperBound)
                let prev = smoothed ?? g
                let coef = g < prev ? fallCoef : riseCoef
                smoothed = coef * prev + (1 - coef) * g
                gainLinear = pow(10, smoothed! / 20)
            }
            let previous = lastApplied ?? gainLinear
            let s0 = counter * stride, e0 = min(s0 + stride, n)
            for f in s0..<e0 {
                let k = Double(f - s0) / Double(stride)
                let g = Float(previous + (gainLinear - previous) * k)
                out.left[f] *= g
                out.right[f] *= g
            }
            lastApplied = gainLinear
        }
        return out
    }
}

// MARK: - Keep (SoundAnalysis)

/// `ClassifySound` → `Keep`: Apple's sound classifier scores 1 s windows every half second; speech
/// windows, and near-speech sounds within `withinMs` of one, are kept; gaps shorter than
/// `shortestCutMs` (also at the head and tail) stay. Outside, the gain fades linearly over `fadeMs`
/// down to `pauseDb` (or silence).
enum Keep {
    final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        var windows: [(start: Double, end: Double, scores: [String: Double])] = []
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var scores: [String: Double] = [:]
            for c in result.classifications { scores[c.identifier] = c.confidence }
            windows.append((result.timeRange.start.seconds, result.timeRange.end.seconds, scores))
        }
    }

    static func keptRanges(_ audio: MicrophoneRenderer.Stereo, sounds: AudioProcessor.KeptSounds) async throws -> [ClosedRange<Double>] {
        let format = AVAudioFormat(standardFormatWithSampleRate: MicrophoneRenderer.sampleRate, channels: 2)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: 1, timescale: 1)
        request.overlapFactor = 0.5
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        let chunk = 48_000
        var start = 0
        while start < audio.count {
            let n = min(chunk, audio.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            audio.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: n) }
            audio.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress! + start, count: n) }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(start))
            start += n
        }
        analyzer.completeAnalysis()
        let windows = collector.windows.map { w in
            (start: w.start, end: w.end,
             speech: sounds.speechLabels.map { w.scores[$0] ?? 0 }.max() ?? 0,
             near: sounds.nearSpeechLabels.map { w.scores[$0] ?? 0 }.max() ?? 0)
        }
        let within = sounds.nearSpeechWithinMs / 1000, shortestCut = sounds.shortestCutMs / 1000
        let speech = windows.filter { $0.speech >= sounds.speechConfidence }.map { ($0.start, $0.end) }
        // Speech windows by start, with the latest end among each prefix: a window is near speech
        // when one starting no later than `within` after it ends no earlier than `within` before.
        let byStart = speech.sorted { $0.0 < $1.0 }
        var latestEnd: [Double] = []
        latestEnd.reserveCapacity(byStart.count)
        for s in byStart { latestEnd.append(max(latestEnd.last ?? -.infinity, s.1)) }
        func isNearSpeech(_ w: (start: Double, end: Double)) -> Bool {
            var lo = 0, hi = byStart.count
            while lo < hi { let mid = (lo + hi) / 2; if byStart[mid].0 - w.end <= within { lo = mid + 1 } else { hi = mid } }
            return lo > 0 && w.start - latestEnd[lo - 1] <= within
        }
        let near = windows.filter { $0.speech < sounds.speechConfidence && $0.near >= sounds.nearSpeechConfidence }
            .filter { isNearSpeech(($0.start, $0.end)) }
            .map { ($0.start, $0.end) }
        var merged: [(Double, Double)] = []
        for r in (speech + near).sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, r.0 - last.1 < shortestCut { merged[merged.count - 1].1 = max(last.1, r.1) } else { merged.append(r) }
        }
        let length = Double(audio.count) / MicrophoneRenderer.sampleRate
        if let first = merged.first, first.0 < shortestCut { merged[0].0 = 0 }
        if let last = merged.last, length - last.1 < shortestCut { merged[merged.count - 1].1 = max(last.0, length) }
        return merged.map { $0.0...$0.1 }
    }

    /// `gain = pause + (1 − pause)·clamp(1 − d / fade, 0, 1)` with `d` the distance to the
    /// nearest kept range; kept audio is never attenuated.
    static func apply(_ audio: MicrophoneRenderer.Stereo, kept: [ClosedRange<Double>], fadeMs: Double, pauseDb: Double?) -> MicrophoneRenderer.Stereo {
        let sr = MicrophoneRenderer.sampleRate
        let pause = pauseDb.map { pow(10, $0 / 20) } ?? 0
        let fade = max(1, (fadeMs / 1000 * sr).rounded())
        var ranges: [(Int, Int)] = []
        for r in kept.map({ k in (Int((k.lowerBound * sr).rounded()), Int((k.upperBound * sr).rounded())) }).sorted(by: { $0.0 < $1.0 }) {
            if let last = ranges.last, r.0 <= last.1 { ranges[ranges.count - 1].1 = max(last.1, r.1) } else { ranges.append(r) }
        }
        var out = audio
        var j = 0
        for p in 0..<audio.count {
            while j < ranges.count && ranges[j].1 <= p { j += 1 }
            var d = Double.infinity
            if j < ranges.count { d = ranges[j].0 <= p ? 0 : Double(ranges[j].0 - p) }
            if j > 0 { d = min(d, Double(p - ranges[j - 1].1 + 1)) }
            let w = clamp(1 - d / fade, 0, 1)
            let g = Float(pause + (1 - pause) * w)
            if g != 1 {
                out.left[p] *= g
                out.right[p] *= g
            }
        }
        return out
    }
}

// MARK: - Apple AudioUnits

/// Neighbouring `audioUnit` steps through one offline `AVAudioEngine`, knobs set by address.
enum AppleUnits {
    static func render(_ audio: MicrophoneRenderer.Stereo, units: [AudioProcessor]) throws -> MicrophoneRenderer.Stereo {
        let format = AVAudioFormat(standardFormatWithSampleRate: MicrophoneRenderer.sampleRate, channels: 2)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var previous: AVAudioNode = player
        var chainLatency: TimeInterval = 0
        for case let .audioUnit(unit, params) in units {
            let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: fourCC(unit.rawValue), componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let effect = AVAudioUnitEffect(audioComponentDescription: description)
            engine.attach(effect)
            for (address, value) in params {
                AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(address), kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
            }
            engine.connect(previous, to: effect, format: format)
            previous = effect
            chainLatency += effect.auAudioUnit.latency
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(audio.count, 1)))!
        input.frameLength = AVAudioFrameCount(audio.count)
        audio.left.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: audio.count) }
        audio.right.withUnsafeBufferPointer { input.floatChannelData![1].update(from: $0.baseAddress!, count: audio.count) }
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        // Render the take plus the units' latency, then drop the latency from the front. The
        // units run in series, so their latencies add up.
        let latency = Int(chainLatency * MicrophoneRenderer.sampleRate)
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(audio.count + latency)
        right.reserveCapacity(audio.count + latency)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while left.count < audio.count + latency {
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(audio.count + latency - left.count))
            let status = try engine.renderOffline(frames, to: buffer)
            guard status == .success else { break }
            let n = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
            right.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n))
        }
        engine.stop()
        let drop = min(latency, left.count)
        return MicrophoneRenderer.Stereo(left: Array(left[drop...].prefix(audio.count)), right: Array(right[drop...].prefix(audio.count)))
    }

    static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
