@preconcurrency import AVFoundation
import Accelerate
import Foundation
import RegravaCore
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
        let measure = Measure(audio)
        var index = 0
        while index < stages.count {
            try Task.checkCancellation()
            // Neighbouring Apple units render through one engine.
            if case .audioUnit = stages[index] {
                var units: [AudioProcessor] = []
                while index < stages.count, case .audioUnit = stages[index] { units.append(stages[index]); index += 1 }
                audio = try AppleUnits.render(audio, units: units)
            } else {
                audio = try await apply(stages[index], to: audio, measure: measure)
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

    private static func apply(_ stage: AudioProcessor, to audio: Stereo, measure: Measure) async throws -> Stereo {
        switch stage {
        case .resample, .audioUnit:
            return audio
        case let .normalize(peakDb, silentChannelBelowDb):
            return ChannelFix.normalize(audio, peakDb: peakDb, silentChannelBelowDb: silentChannelBelowDb)
        case let .leveler(targetDb, holdBelowSpeechDb, floorDb, gainRangeDb, windowMs, lookMs, fallMs, riseMs):
            return Leveler.process(audio, speechLevelDb: Measure(audio).typicalLoudLevelDb, targetDb: targetDb, holdBelowSpeechDb: holdBelowSpeechDb, floorDb: floorDb, gainRangeDb: gainRangeDb, windowMs: windowMs, lookMs: lookMs, fallMs: fallMs, riseMs: riseMs)
        case let .keep(sounds, fadeMs, pauseDb):
            let ranges = try await Keep.keptRanges(audio, sounds: sounds)
            return Keep.apply(audio, kept: ranges, fadeMs: fadeMs ?? 10, pauseDb: pauseDb)
        case .mossFormer2, .tfRestormer:
            throw RenderError.needsSpeechModels
        case .matchEq, .dynamicEq, .restoreSibilance:
            // Only in the Podcast chain, which needs the speech models too.
            throw RenderError.needsSpeechModels
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

/// Speech models (MossFormer2, TF-Restormer) are not implemented yet.
public enum SpeechModels {
    public static var isAvailable: Bool { false }
}

// MARK: - Measure, normalize

/// A first pass over the take (`Measure`): levels the other steps read.
struct Measure {
    /// The level speech typically reaches (dBFS), from 400 ms RMS windows: the 90th percentile of
    /// the windows above −60 dB.
    let typicalLoudLevelDb: Double

    init(_ audio: MicrophoneRenderer.Stereo) {
        let window = Int(MicrophoneRenderer.sampleRate * 0.4)
        var levels: [Double] = []
        var start = 0
        while start + window <= audio.count {
            var sum: Float = 0
            audio.left.withUnsafeBufferPointer { l in audio.right.withUnsafeBufferPointer { r in
                var a: Float = 0, b: Float = 0
                vDSP_svesq(l.baseAddress! + start, 1, &a, vDSP_Length(window))
                vDSP_svesq(r.baseAddress! + start, 1, &b, vDSP_Length(window))
                sum = (a + b) / 2
            } }
            let db = 10 * log10(Double(sum) / Double(window) + 1e-12)
            if db > -60 { levels.append(db) }
            start += window / 2
        }
        levels.sort()
        typicalLoudLevelDb = levels.isEmpty ? -30 : levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))]
    }
}

enum ChannelFix {
    static func rmsDb(_ x: [Float]) -> Double {
        var ms: Float = 0
        vDSP_measqv(x, 1, &ms, vDSP_Length(x.count))
        return 10 * log10(Double(ms) + 1e-12)
    }

    /// `normalize`: a channel `silentChannelBelowDb` or more under the other becomes a copy of
    /// it; then the peak goes to `peakDb` (nil keeps the level).
    static func normalize(_ audio: MicrophoneRenderer.Stereo, peakDb: Double?, silentChannelBelowDb: Double) -> MicrophoneRenderer.Stereo {
        var out = audio
        let l = rmsDb(audio.left), r = rmsDb(audio.right)
        if l - r >= silentChannelBelowDb { out.right = out.left } else if r - l >= silentChannelBelowDb { out.left = out.right }
        guard let peakDb else { return out }
        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(out.left, 1, &pl, vDSP_Length(out.count))
        vDSP_maxmgv(out.right, 1, &pr, vDSP_Length(out.count))
        let peak = max(pl, pr)
        guard peak > 1e-6 else { return out }
        var gain = Float(pow(10, peakDb / 20)) / peak
        vDSP_vsmul(out.left, 1, &gain, &out.left, 1, vDSP_Length(out.count))
        vDSP_vsmul(out.right, 1, &gain, &out.right, 1, vDSP_Length(out.count))
        return out
    }
}

// MARK: - Leveler

/// "Brings speech to `targetDb` over seconds. Holds still in pauses so noise never comes up." The
/// gain follows the windowed level (looking `lookMs` ahead), rising over `riseMs` and falling over
/// `fallMs`, and holds where the level is `holdBelowSpeechDb` under speech or under `floorDb`.
enum Leveler {
    static func process(_ audio: MicrophoneRenderer.Stereo, speechLevelDb: Double, targetDb: Double, holdBelowSpeechDb: Double, floorDb: Double, gainRangeDb: ClosedRange<Double>, windowMs: Double, lookMs: Double, fallMs: Double, riseMs: Double) -> MicrophoneRenderer.Stereo {
        let sr = MicrophoneRenderer.sampleRate
        let hop = 480 // 10 ms control rate
        let window = max(Int(sr * windowMs / 1000), hop)
        let look = Int(sr * lookMs / 1000)
        let n = audio.count
        guard n > 0 else { return audio }
        // Mean square per hop, then a running window.
        let hops = (n + hop - 1) / hop
        var power = [Double](repeating: 0, count: hops)
        for h in 0..<hops {
            let s = h * hop, e = min(s + hop, n)
            var sum = 0.0
            for i in s..<e { sum += Double(audio.left[i] * audio.left[i] + audio.right[i] * audio.right[i]) / 2 }
            power[h] = sum / Double(max(e - s, 1))
        }
        let span = max(window / hop, 1), ahead = look / hop
        var gainsDb = [Double](repeating: 0, count: hops)
        var current = clamp(targetDb - speechLevelDb, gainRangeDb.lowerBound, gainRangeDb.upperBound)
        let riseCoef = exp(-Double(hop) / (sr * max(riseMs, 1) / 1000))
        let fallCoef = exp(-Double(hop) / (sr * max(fallMs, 1) / 1000))
        var prefix = [Double](repeating: 0, count: hops + 1)
        for h in 0..<hops { prefix[h + 1] = prefix[h] + power[h] }
        for h in 0..<hops {
            let centre = h + ahead
            let lo = max(0, centre - span / 2), hi = min(hops, centre + span / 2 + 1)
            let level = 10 * log10((prefix[hi] - prefix[lo]) / Double(max(hi - lo, 1)) + 1e-12)
            if level > floorDb && level > speechLevelDb - holdBelowSpeechDb {
                let wanted = clamp(targetDb - level, gainRangeDb.lowerBound, gainRangeDb.upperBound)
                let coef = wanted > current ? riseCoef : fallCoef
                current = wanted + (current - wanted) * coef
            }
            gainsDb[h] = current
        }
        var out = audio
        for i in 0..<n {
            let h = i / hop
            let t = Double(i % hop) / Double(hop)
            let next = min(h + 1, hops - 1)
            let g = Float(pow(10, (gainsDb[h] + (gainsDb[next] - gainsDb[h]) * t) / 20))
            out.left[i] *= g
            out.right[i] *= g
        }
        return out
    }
}

// MARK: - Keep (SoundAnalysis)

/// "Silence outside the speech, and the sounds near it": Apple's sound classifier scores 1 s
/// windows every half second; a stretch with neither speech nor a nearby kept sound, at least
/// `shortestCutMs` long, is turned down to `pauseDb` (or silenced) with `fadeMs` fades.
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
        let format = AVAudioFormat(standardFormatWithSampleRate: MicrophoneRenderer.sampleRate, channels: 1)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        let chunk = 48_000
        var start = 0
        while start < audio.count {
            let n = min(chunk, audio.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { buffer.floatChannelData![0][i] = (audio.left[start + i] + audio.right[start + i]) / 2 }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(start))
            start += n
        }
        analyzer.completeAnalysis()
        let windows = collector.windows
        let speech = windows.filter { w in sounds.speechLabels.contains { (w.scores[$0] ?? 0) >= sounds.speechConfidence } }
        let near = windows.filter { w in
            sounds.nearSpeechLabels.contains { (w.scores[$0] ?? 0) >= sounds.nearSpeechConfidence }
                && speech.contains { s in s.start - sounds.nearSpeechWithinMs / 1000 <= w.end && w.start <= s.end + sounds.nearSpeechWithinMs / 1000 }
        }
        // Merge kept windows; gaps shorter than `shortestCutMs` stay kept.
        let kept = (speech + near).map { $0.start...$0.end }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in kept {
            if let last = merged.last, range.lowerBound - last.upperBound < sounds.shortestCutMs / 1000 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        // The edges count as kept unless the cut there is long enough too.
        let duration = Double(audio.count) / MicrophoneRenderer.sampleRate
        if let first = merged.first, first.lowerBound < sounds.shortestCutMs / 1000 { merged[0] = 0...first.upperBound }
        if let last = merged.last, duration - last.upperBound < sounds.shortestCutMs / 1000 { merged[merged.count - 1] = last.lowerBound...duration }
        return merged
    }

    static func apply(_ audio: MicrophoneRenderer.Stereo, kept: [ClosedRange<Double>], fadeMs: Double, pauseDb: Double?) -> MicrophoneRenderer.Stereo {
        let sr = MicrophoneRenderer.sampleRate
        let low = Float(pauseDb.map { pow(10, $0 / 20) } ?? 0)
        let fade = max(sr * fadeMs / 1000, 1)
        var out = audio
        // Gain 1 inside kept ranges, `low` elsewhere, ramping over `fade` samples at each edge.
        var target = [Float](repeating: low, count: audio.count)
        for range in kept {
            let s = max(Int(range.lowerBound * sr), 0), e = min(Int(range.upperBound * sr), audio.count)
            if s < e { for i in s..<e { target[i] = 1 } }
        }
        var g: Float = target.first ?? 1
        let step = (1 - low) / Float(fade)
        for i in 0..<audio.count {
            if g < target[i] { g = min(target[i], g + step) } else if g > target[i] { g = max(target[i], g - step) }
            out.left[i] *= g
            out.right[i] *= g
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
        for case let .audioUnit(unit, params) in units {
            let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: fourCC(unit.rawValue), componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let effect = AVAudioUnitEffect(audioComponentDescription: description)
            engine.attach(effect)
            for (address, value) in params {
                AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(address), kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
            }
            engine.connect(previous, to: effect, format: format)
            previous = effect
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

        // Render the take plus the units' latency, then drop the latency from the front.
        let latency = Int(((previous as? AVAudioUnit)?.auAudioUnit.latency ?? 0) * MicrophoneRenderer.sampleRate)
            + units.indices.reduce(0) { _, _ in 0 }
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
