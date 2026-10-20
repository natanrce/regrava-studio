import AVFoundation
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct SilenceAnalyzerTests {
    @Test func findsTheQuietStretchOfTheMicrophone() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(rate * 5)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            let t = Double(i) / rate
            let loud = t < 1 || t >= 4
            buffer.floatChannelData![0][i] = loud ? Float(sin(t * 2 * .pi * 440) * 0.5) : Float(sin(t * 2 * .pi * 440) * 0.01)
        }
        try file.write(from: buffer)
        let silence = try await SilenceAnalyzer.analyze(recording: url, audioTrackIndex: 0, hideDuringSilenceMs: 2000)
        #expect(silence.minSilenceDurationMs == 2000)
        #expect(silence.chunks.count == 1)
        let chunk = try #require(silence.chunks.first)
        #expect(abs(chunk.startMs - 1000) <= 50 && abs(chunk.endMs - 4000) <= 50)
    }
}
