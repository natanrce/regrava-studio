import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import RegravaCore
@testable import RegravaRender

@Suite struct ExportEncoderSettingsTests {
    private func compression(_ settings: ExportSettings, _ codec: ExportCodec, _ size: Size2) -> [String: Any] {
        ProjectExporter.videoOutputSettings(settings: settings, codec: codec, size: size)[AVVideoCompressionPropertiesKey] as! [String: Any]
    }

    @Test func hevcRunsAtTheQualityBitrate() {
        var s = ExportSettings.defaults(for: .mp4)
        s.quality = .studio
        let size = Size2(width: 1920, height: 1080)
        let output = ProjectExporter.videoOutputSettings(settings: s, codec: .h265, size: size)
        #expect(output[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let c = compression(s, .h265, size)
        #expect(c[AVVideoAverageBitRateKey] as? Int == 37_324_800)
        #expect(c[AVVideoMaxKeyFrameIntervalKey] as? Int == 120)
        #expect(c[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main_AutoLevel as String)
        #expect(c[AVVideoExpectedSourceFrameRateKey] == nil)
    }

    @Test func h264ConvertsItsQuantizerToTheFallbackBitrate() {
        var s = ExportSettings.defaults(for: .mp4)
        s.quality = .webLow
        s.fps = 30
        let c = compression(s, .h264, Size2(width: 1280, height: 720))
        #expect(c[AVVideoAverageBitRateKey] as? Int == 207_360)
        #expect(c[AVVideoMaxKeyFrameIntervalKey] as? Int == 60)
        #expect(c[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
    }

    @Test func everyVideoIsTaggedBT709() {
        for format in [ExportFormat.mp4, .prores] {
            let output = ProjectExporter.videoOutputSettings(settings: .defaults(for: format), codec: .h264, size: Size2(width: 1280, height: 720))
            let color = output[AVVideoColorPropertiesKey] as? [String: String]
            #expect(color?[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_709_2)
            #expect(color?[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_709_2)
            #expect(color?[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_709_2)
        }
        #expect(ProjectExporter.videoOutputSettings(settings: .defaults(for: .prores), codec: nil, size: Size2(width: 1920, height: 1080))[AVVideoCompressionPropertiesKey] == nil)
    }
}
