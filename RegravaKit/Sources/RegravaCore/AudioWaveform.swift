import Foundation

// The timeline's audio waveform.

public enum AudioWaveform {
    /// 800 levels a second (`audio.waveform`, samplesPerSecond: 800).
    public static let samplesPerSecond = 800
    public static let samplesPerMs = 0.8
    /// The tallest the waveform gets, from the clip's bottom edge (`SLICE_WAVEFORM_HEIGHT_PX`).
    public static let heightPx = 32.0

    /// Levels 0…1 against the take's loud parts: the 95th percentile of its per-second peaks,
    /// so one click does not flatten a quiet take (`getAudioWaveform`).
    public static func normalized(peaks: [Float]) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        var perSecond: [Float] = []
        var index = 0
        while index < peaks.count {
            perSecond.append(peaks[index..<min(index + samplesPerSecond, peaks.count)].max() ?? 0)
            index += samplesPerSecond
        }
        let sorted = perSecond.sorted()
        let reference = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))]
        guard reference > 0 else { return Array(repeating: 0, count: peaks.count) }
        return peaks.map { min(max($0 / reference, 0), 1) }
    }
}

/// Max-mip pyramid of a waveform: level L bin i is the peak of samples [i·2^L, (i+1)·2^L); reads
/// blend two levels by the bin width, each with Catmull-Rom.
public struct WaveformPyramid: Sendable {
    public let levels: [[Float]]

    public init(samples: [Float]) {
        var levels = [samples]
        while let last = levels.last, last.count > 1, levels.count < 31 {
            levels.append((0..<(last.count + 1) / 2).map { i in max(last[2 * i], last[min(2 * i + 1, last.count - 1)]) })
        }
        self.levels = levels
    }

    public var sampleCount: Int { levels[0].count }

    /// Out-of-range bins read as 0, so the envelope tapers at the ends.
    @inline(__always) private func bin(_ level: [Float], _ i: Int) -> Double {
        i >= 0 && i < level.count ? Double(level[i]) : 0
    }

    func read(level index: Int, at position: Double) -> Double {
        let level = levels[index]
        let p = position / Double(1 << index) - 0.5
        let i = Int(p.rounded(.down)), t = p - Double(i)
        let b = bin(level, i - 1), l = bin(level, i), r = bin(level, i + 1), a = bin(level, i + 2)
        let lin = r - b, quad = 2 * b - 5 * l + 4 * r - a, cub = 3 * (l - r) + a - b
        return min(max(l + 0.5 * t * (lin + t * (quad + t * cub)), 0), 1)
    }

    /// `$readWaveformEnvelope(samplePosition, samplesPerBin)`.
    public func envelope(at position: Double, samplesPerBin: Double) -> Double {
        guard sampleCount > 0 else { return 0 }
        let level = min(max(log2(max(samplesPerBin, 1)), 0), Double(levels.count - 1))
        let l0 = Int(level), l1 = min(l0 + 1, levels.count - 1)
        let low = read(level: l0, at: position)
        return l0 == l1 ? low : low + (read(level: l1, at: position) - low) * (level - Double(l0))
    }
}
