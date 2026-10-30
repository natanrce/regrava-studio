import Foundation

/// Expected size of one exported file, with the spread content can cause.
public struct ExportSizeEstimate: Equatable, Sendable {
    /// The MP4 codec this file is for (nil for GIF and ProRes).
    public var codec: ExportCodec?
    public var typicalBytes: Double
    public var lowBytes: Double
    public var highBytes: Double
}

/// The export picker's time and size estimates.
public enum ExportEstimator {
    struct Rate {
        var bitsPerSecond: Double
        var low: Double
        var high: Double
    }

    static let referencePixels = 1920.0 * 1080
    static let referenceFps = 60.0

    /// Bits per pixel at 1080p60 by constant rate factor, interpolated in log space.
    static let crfTable: [(crf: Double, bitsPerPixel: Double)] = [(14, 0.0816), (24, 0.0221), (30, 0.011), (42, 0.0038)]

    /// MP4 sound in the size estimate.
    public static let mp4AudioBitsPerSecond = 165_000.0
    /// ProRes sound in the size estimate: 48 kHz, 24-bit, stereo.
    public static let proResAudioBitsPerSecond = 48_000.0 * 24 * 2

    /// Linear interpolation over a strictly increasing input range, extended past both ends.
    static func interpolate(_ x: Double, _ input: [Double], _ output: [Double]) -> Double {
        var i = 1
        while i < input.count - 1 && !(input[i] >= x) { i += 1 }
        let (x0, x1, y0, y1) = (input[i - 1], input[i], output[i - 1], output[i])
        if y0 == y1 { return y0 }
        return (x - x0) / (x1 - x0) * (y1 - y0) + y0
    }

    static func h264Rate(crf: Double, pixels: Double, fps: Double) -> Rate {
        let logBpp = interpolate(crf, crfTable.map(\.crf), crfTable.map { log($0.bitsPerPixel) })
        let bps = exp(logBpp) * referencePixels * referenceFps * pow(pixels / referencePixels, 0.78) * pow(fps / referenceFps, 0.57)
        return Rate(bitsPerSecond: bps, low: 0.65, high: 1.5)
    }

    static func hevcRate(bitsPerSecond: Double, pixels: Double, fps: Double) -> Rate {
        Rate(bitsPerSecond: max(bitsPerSecond * 0.93, pixels * fps * 0.01), low: 0.8, high: 1.1)
    }

    static func gifRate(mode: GifQualityMode, pixels: Double, fps: Double) -> Rate {
        let basePixels = 852.0 * 480
        let baseFps = 15.0
        let bitsPerPixel = mode == .high ? 0.575 : 0.45
        let bps = bitsPerPixel * basePixels * baseFps * pow(pixels / basePixels, 0.9) * pow(fps / baseFps, 0.77)
        return Rate(bitsPerSecond: bps, low: 0.55, high: 1.65)
    }

    static func proResRate(profile: ProResProfile, pixels: Double, fps: Double) -> Rate {
        let bitsPerPixel: Double = switch profile {
        case .lt: 1.21
        case .standard: 2.09
        case .hq: 3.36
        case .p4444: 4.74
        }
        return Rate(bitsPerSecond: bitsPerPixel * referencePixels * pow(pixels / referencePixels, 0.84) * fps, low: 0.85, high: 1.2)
    }

    /// One estimate per written file.
    public static func sizes(settings: ExportSettings, codecs: [ExportCodec], width: Double, height: Double, durationMs: Double, hasAudio: Bool) -> [ExportSizeEstimate] {
        let pixels = width * height
        let fps = Double(settings.fps)
        func estimate(_ codec: ExportCodec?, _ rate: Rate, audio: Double) -> ExportSizeEstimate {
            func bytes(_ bps: Double) -> Double { (bps + audio) / 8 * (durationMs / 1000) }
            return ExportSizeEstimate(codec: codec, typicalBytes: bytes(rate.bitsPerSecond),
                                      lowBytes: bytes(rate.bitsPerSecond * rate.low), highBytes: bytes(rate.bitsPerSecond * rate.high))
        }
        switch settings.format {
        case .gif:
            return [estimate(nil, gifRate(mode: settings.quality.gifMode, pixels: pixels, fps: fps), audio: 0)]
        case .prores:
            return [estimate(nil, proResRate(profile: settings.proresProfile, pixels: pixels, fps: fps), audio: hasAudio ? proResAudioBitsPerSecond : 0)]
        case .mp4:
            let audio = hasAudio ? mp4AudioBitsPerSecond : 0
            return codecs.map { codec in
                let control = ExportEncoding.rateControl(codec: codec, quality: settings.quality, width: width, height: height, fps: settings.fps)
                let rate = control.rateMode == .crf
                    ? h264Rate(crf: control.rate, pixels: pixels, fps: fps)
                    : hevcRate(bitsPerSecond: control.rate, pixels: pixels, fps: fps)
                return estimate(codec, rate, audio: audio)
            }
        }
    }

    /// "12MB", or a range like "12–30MB" when the high estimate is at least 1.5× the low one.
    public static func sizeText(_ estimate: ExportSizeEstimate) -> String {
        if estimate.highBytes / estimate.lowBytes < 1.5 {
            let typical = formatBytes(estimate.typicalBytes)
            return typical.amount + typical.unit
        }
        let low = formatBytes(estimate.lowBytes)
        let high = formatBytes(estimate.highBytes)
        if low.unit == high.unit {
            return low.amount == high.amount ? high.amount + high.unit : "\(low.amount)–\(high.amount)\(high.unit)"
        }
        return "\(low.amount)\(low.unit)–\(high.amount)\(high.unit)"
    }

    /// KB under 995 KB (whole KB under 100, else tens), MB with one decimal under 25 MB, then
    /// steps of 5 under 100 MB and 10 under 1000 MB, then GB with one decimal.
    public static func formatBytes(_ bytes: Double) -> (amount: String, unit: String) {
        let kb = bytes / 1000
        if kb < 100 { return (String(Int(max(1, roundHalfUp(kb)))), "KB") }
        if kb < 995 { return (String(Int(roundToStep(kb, 10))), "KB") }
        let mb = bytes / 1_000_000
        if mb < 25 { return (fixed1(mb), "MB") }
        let stepped = roundToStep(mb, mb < 100 ? 5 : 10)
        if stepped < 1000 { return (String(Int(stepped)), "MB") }
        return (fixed1(mb / 1000), "GB")
    }

    /// Expected export time: frames × time per frame, the time per frame interpolated by pixel
    /// count between 720p (a third of 4K's) and 4K.
    public static func exportTimeMs(width: Double, height: Double, durationMs: Double, fps: Int) -> Double {
        let pixels4K = 3840.0 * 2160
        let msPerPixelFrame = 1200.0 * 1000 / (31.5 * 60 * 1000 / 1000 * 60) / pixels4K
        let pixels = interpolate(width * height, [1280 * 720, pixels4K], [pixels4K / 3, pixels4K])
        return pixels * (durationMs / 1000 * Double(fps)) * msPerPixelFrame * 2
    }

    /// "45 seconds", "3 minutes", "1 hour 5 minutes".
    public static func timeText(ms: Double) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let seconds = Int(roundHalfUp(ms / 1000))
        if seconds < 60 { return plural(seconds, "second", "seconds") }
        let minutes = Int(roundHalfUp(Double(seconds) / 60))
        if minutes < 60 { return plural(minutes, "minute", "minutes") }
        return plural(minutes / 60, "hour", "hours") + " " + plural(minutes % 60, "minute", "minutes")
    }

    /// The picker's "Export time" and "Output size" texts. "Both" lists each file with its codec.
    public static func texts(settings: ExportSettings, target: ExportTarget?, aspectRatio: Double, durationMs: Double, hasAudio: Bool) -> (time: String, size: String) {
        let size = settings.outputSize(aspectRatio: aspectRatio)
        let time = exportTimeMs(width: size.width, height: size.height, durationMs: durationMs, fps: settings.fps)
        let timeLabel = timeText(ms: settings.format == .gif ? time * 1.3 : time)
        let estimates = sizes(settings: settings, codecs: ExportEncoding.codecs(settings.codec, target: target ?? .link),
                              width: size.width, height: size.height, durationMs: durationMs, hasAudio: hasAudio)
        let sizeLabel = estimates.count == 1
            ? sizeText(estimates[0])
            : estimates.map { estimate in
                let text = sizeText(estimate)
                return estimate.codec.map { "\(text) \($0.label)" } ?? text
            }.joined(separator: ", ")
        return (timeLabel, sizeLabel)
    }

    static func roundHalfUp(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    static func roundToStep(_ x: Double, _ step: Double) -> Double { roundHalfUp(x / step) * step }

    /// One decimal, an exact tie rounding up.
    static func fixed1(_ x: Double) -> String {
        let tens = x * 10
        let isExact = (-tens).addingProduct(x, 10) == 0
        if isExact, tens - tens.rounded(.down) == 0.5 {
            return String(format: "%.1f", tens.rounded(.up) / 10)
        }
        return String(format: "%.1f", x)
    }
}

public extension Project {
    /// Whether the export carries sound: recorded audio, background music, click effects or
    /// click sounds.
    var exportHasAudio: Bool {
        let recordingHasAudio = recording.hasMicrophone || recording.hasSystemAudio || recording.hasExternalDeviceAudio
        let hasBackgroundAudio = !(audio.backgroundAudioFileName ?? "").isEmpty
        let needsAudio = recordingHasAudio || hasBackgroundAudio || cursor.clickEffect != nil
        return needsAudio || audio.clickSoundEffect != nil
    }
}
