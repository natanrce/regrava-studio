import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct MicrophoneRendererTests {
    @Test func channelFixCopiesASilentChannelAndNormalizesThePeak() {
        let n = 48_000
        let left = (0..<n).map { Float(sin(Double($0) * 0.05) * 0.1) }
        let audio = MicrophoneRenderer.Stereo(left: left, right: [Float](repeating: 0.0001, count: n))
        let out = ChannelFix.normalize(audio, peakDb: -6, silentChannelBelowDb: 30)
        #expect(out.right == out.left)
        let peak = out.left.map(abs).max()!
        #expect(abs(20 * log10(Double(peak)) + 6) < 0.01)
        // Off keeps the level.
        #expect(ChannelFix.normalize(audio, peakDb: nil, silentChannelBelowDb: 30).left == left)
    }

    @Test func keepTurnsCutsDownWithFades() {
        let n = 48_000 * 3
        let audio = MicrophoneRenderer.Stereo(left: [Float](repeating: 1, count: n), right: [Float](repeating: 1, count: n))
        let out = Keep.apply(audio, kept: [0...1], fadeMs: 400, pauseDb: -20)
        #expect(out.left[24_000] == 1)
        #expect(abs(out.left[n - 1] - 0.1) < 1e-4)
    }

    @Test func chainsAndNames() {
        #expect(MicrophoneAudioPreset.loud.chain.count == 7)
        #expect(MicrophoneAudioPreset.podcast.needsSpeechModels && MicrophoneAudioPreset.noiseReduction.needsSpeechModels && !MicrophoneAudioPreset.loud.needsSpeechModels)
        #expect(MicrophoneAudioPreset.voice.renderFileName(take: "microphone") == "microphone.iX1Wu7lsa1zS0Vx0oTNIwXFWSN7IypT2.m4a")
    }
}
