import Foundation
import Testing
@testable import RegravaCore

struct AudioWaveformTests {
    @Test func pyramidKeepsPeaks() {
        let pyramid = WaveformPyramid(samples: [0, 0.2, 0.9, 0.1, 0.3])
        #expect(pyramid.levels.map(\.count) == [5, 3, 2, 1])
        #expect(pyramid.levels[1] == [0.2, 0.9, 0.3])
        #expect(pyramid.levels[3] == [0.9])
    }

    @Test func envelopeHitsBinCentres() {
        let pyramid = WaveformPyramid(samples: [0, 0, 1, 0, 0, 0, 0, 0])
        #expect(abs(pyramid.envelope(at: 2.5, samplesPerBin: 1) - 1) < 1e-9)
        #expect(pyramid.envelope(at: 6.5, samplesPerBin: 1) == 0)
        // Wider bins read coarser levels, which still hold the peak.
        #expect(pyramid.envelope(at: 2, samplesPerBin: 4) > 0.5)
    }

    @Test func normalizesAgainstLoudSeconds() {
        var peaks = [Float](repeating: 0.5, count: 800 * 20)
        peaks[10] = 4 // one click
        let levels = AudioWaveform.normalized(peaks: peaks)
        #expect(levels[100] == 1)
        #expect(levels[10] == 1)
    }
}
