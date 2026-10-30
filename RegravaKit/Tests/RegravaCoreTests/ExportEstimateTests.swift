import Foundation
import Testing
@testable import RegravaCore

@Suite struct ExportEncodingTests {
    @Test func h264UsesConstantRateFactor() {
        let rates = ExportQuality.allCases.map {
            ExportEncoding.rateControl(codec: .h264, quality: $0, width: 1920, height: 1080, fps: 60)
        }
        #expect(rates.map(\.rate) == [14, 24, 30, 42])
        #expect(rates.allSatisfy { $0.encoder == .videoEncoder && $0.rateMode == .crf })
    }

    @Test func hevcUsesHardwareBitrate() {
        let studio = ExportEncoding.rateControl(codec: .h265, quality: .studio, width: 1920, height: 1080, fps: 60)
        #expect(studio == VideoRateControl(codec: .h265, encoder: .hardware, rateMode: .bitrate, rate: 37_324_800))
        #expect(ExportEncoding.bitsPerSecond(quality: .webHigh, width: 1214, height: 2160, fps: 30) == 1_376_676)
        #expect(ExportEncoding.hardwareBitsPerSecond(codec: .h264, quality: .studio, width: 1920, height: 1080, fps: 60) == 37_324_800)
    }

    @Test func codecsPerTarget() {
        #expect(ExportEncoding.codecs(.both, target: .file) == [.h264, .h265])
        #expect(ExportEncoding.codecs(.both, target: .clipboard) == [.h264])
        #expect(ExportEncoding.codecs(.h265, target: .link) == [.h265])
    }

    @Test func keyframesEveryTwoSeconds() {
        #expect(ExportEncoding.maxKeyFrameInterval(fps: 60) == 120)
        #expect(ExportEncoding.maxKeyFrameInterval(fps: 1) == 2)
    }

    @Test func gifModes() {
        #expect(ExportQuality.studio.gifMode == .high)
        #expect(ExportQuality.socialMedia.gifMode == .balanced)
    }
}

@Suite struct ExportEstimateTests {
    private func settings(_ format: ExportFormat, _ quality: ExportQuality, fps: Int, codec: ExportCodec = .h264, profile: ProResProfile = .hq) -> ExportSettings {
        ExportSettings(format: format, fps: fps, quality: quality, height: 1080, codec: codec, proresProfile: profile)
    }

    private func texts(_ s: ExportSettings, codecs: [ExportCodec], _ w: Double, _ h: Double, ms: Double, audio: Bool) -> (time: String, size: String, typical: [Double]) {
        let estimates = ExportEstimator.sizes(settings: s, codecs: codecs, width: w, height: h, durationMs: ms, hasAudio: audio)
        let size = estimates.count == 1 ? ExportEstimator.sizeText(estimates[0])
            : estimates.map { "\(ExportEstimator.sizeText($0)) \($0.codec!.label)" }.joined(separator: ", ")
        var time = ExportEstimator.exportTimeMs(width: w, height: h, durationMs: ms, fps: s.fps)
        if s.format == .gif { time *= 1.3 }
        return (ExportEstimator.timeText(ms: time), size, estimates.map(\.typicalBytes))
    }

    private func close(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= abs($1) * 1e-9 }
    }

    @Test func h264SocialMedia720p() {
        let r = texts(settings(.mp4, .socialMedia, fps: 60), codecs: [.h264], 1280, 720, ms: 30_000, audio: true)
        #expect(r.time == "13 seconds")
        #expect(r.size == "4.2–8.8MB")
        #expect(close(r.typical, [6_096_439.512648896]))
    }

    @Test func bothCodecsAt4K() {
        let r = texts(settings(.mp4, .studio, fps: 60, codec: .both), codecs: [.h264, .h265], 3840, 2160, ms: 600_000, audio: true)
        #expect(r.time == "13 minutes")
        #expect(r.size == "1.5–3.4GB H.264, 10.4GB HEVC")
        #expect(close(r.typical, [2_257_468_590.2071133, 10_425_994_200]))
    }

    @Test func hevcWebLowWithoutAudio() {
        let r = texts(settings(.mp4, .webLow, fps: 30, codec: .h265), codecs: [.h265], 1920, 1080, ms: 5000, audio: false)
        #expect(r.time == "1 second")
        #expect(r.size == "390KB")
        #expect(close(r.typical, [388_800]))
    }

    @Test func gifQualityChangesSize() {
        let high = texts(settings(.gif, .studio, fps: 15), codecs: [], 852, 480, ms: 10_000, audio: true)
        let balanced = texts(settings(.gif, .socialMedia, fps: 15), codecs: [], 852, 480, ms: 10_000, audio: true)
        #expect(high.size == "2.4–7.3MB")
        #expect(balanced.size == "1.9–5.7MB")
        #expect(close(high.typical, [4_409_100]))
        #expect(close(balanced.typical, [3_450_600]))
    }

    @Test func proResWithPCMAudio() {
        let r = texts(settings(.prores, .studio, fps: 60), codecs: [], 1920, 1080, ms: 4_000_000, audio: true)
        #expect(r.time == "37 minutes")
        #expect(r.size == "210.2GB")
        #expect(close(r.typical, [210_170_880_000]))
    }

    @Test func shortClipInKilobytes() {
        let r = texts(settings(.mp4, .webHigh, fps: 24), codecs: [.h264], 1280, 720, ms: 900, audio: false)
        #expect(r.time == "0 seconds")
        #expect(r.size == "32–73KB")
    }

    @Test func byteFormatting() {
        let cases: [(Double, String)] = [
            (50, "1KB"), (99_499, "99KB"), (99_500, "100KB"), (994_999, "990KB"), (995_000, "1.0MB"),
            (1_250_000, "1.3MB"), (24_950_000, "24.9MB"), (24_960_000, "25.0MB"), (27_400_000, "25MB"),
            (99_000_000, "100MB"), (123_456_789, "120MB"), (994_999_999, "990MB"), (995_000_000, "1.0GB"),
            (1_234_567_890, "1.2GB"),
        ]
        for (bytes, text) in cases {
            let f = ExportEstimator.formatBytes(bytes)
            #expect(f.amount + f.unit == text, "\(bytes)")
        }
    }

    @Test func timeFormatting() {
        let cases: [(Double, String)] = [
            (400, "0 seconds"), (59_400, "59 seconds"), (59_600, "1 minute"), (89_999, "2 minutes"),
            (3_569_000, "59 minutes"), (3_570_000, "1 hour 0 minutes"), (3_900_000, "1 hour 5 minutes"),
            (7_260_000, "2 hours 1 minute"),
        ]
        for (ms, text) in cases { #expect(ExportEstimator.timeText(ms: ms) == text) }
    }

    @Test func pickerTextsUseOutputSizeAndTarget() {
        var s = ExportSettings.defaults(for: .mp4)
        s.codec = .both
        let file = ExportEstimator.texts(settings: s, target: .file, aspectRatio: 16.0 / 9, durationMs: 30_000, hasAudio: true)
        let clipboard = ExportEstimator.texts(settings: s, target: .clipboard, aspectRatio: 16.0 / 9, durationMs: 30_000, hasAudio: true)
        #expect(file.size.hasSuffix(" HEVC"))
        #expect(clipboard.size == "4.2–8.8MB")
        #expect(clipboard.time == "13 seconds")
    }
}
