import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct PodcastProcessorTests {
    func tone(_ hz: Double, _ n: Int = 48_000, amplitude: Float = 0.3) -> [Float] {
        (0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 48_000)) }
    }

    @Test func stftRoundTripIsUnity() {
        for frame in [1024, 1920, 2048, 4096] {
            let stft = Stft(frame: frame)
            let x = tone(440)
            let frames = stft.analyze(x)
            let y = stft.synthesize(frames, length: x.count)
            let err = zip(x, y).dropFirst(frame).dropLast(frame).map { abs($0 - $1) }.max() ?? 1
            #expect(err < 1e-3)
        }
    }

    @Test func deEsserCutsSibilanceOnly() {
        // A 7 kHz burst over a 300 Hz tone: the de-esser turns the 7 kHz part down, not the tone.
        let low = tone(300), high = tone(7000, amplitude: 0.3)
        let mixed = MicrophoneRenderer.Stereo(left: zip(low, high).map(+), right: zip(low, high).map(+))
        let out = DynamicEq.process(mixed, frame: 1024, detectorHz: 5000...9000, referenceHz: nil, allowedDb: -23, ratio: 4, maxCutDb: 8, cutHz: 3500...12500, taperOctaves: 0.3, attackMs: 1, releaseMs: 50)
        let stft = Stft(frame: 4096)
        func level(_ x: [Float], _ hz: ClosedRange<Double>) -> Double {
            let frames = stft.analyze(x)
            let power = (0..<stft.bins).map { k in frames[5].re[k] * frames[5].re[k] + frames[5].im[k] * frames[5].im[k] }
            return stft.level(power, stft.bins(in: hz))
        }
        #expect(level(mixed.left, 6500...7500) - level(out.left, 6500...7500) > 4)
        #expect(abs(level(mixed.left, 250...350) - level(out.left, 250...350)) < 0.5)
    }

    @Test func matchEqKeepsOneKilohertz() {
        let x = tone(1000)
        let audio = MicrophoneRenderer.Stereo(left: x, right: x)
        let flat = [Double](repeating: 0, count: 25)
        var target = flat
        target[12] = 10 // only 1 kHz asked higher: renormalized to 0 dB there
        let out = MatchEq.process(audio, measuredBands: flat, target: target, correctionDb: -15...12)
        let mid = 24_000
        #expect(abs(out.left[mid...mid + 1000].map(abs).max()! - x[mid...mid + 1000].map(abs).max()!) < 0.02)
    }
}
