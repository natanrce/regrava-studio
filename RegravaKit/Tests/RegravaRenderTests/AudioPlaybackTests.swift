import AVFoundation
import XCTest
@testable import RegravaCore
@testable import RegravaRender

final class AudioPlaybackTests: XCTestCase {
    private func read(_ ring: AudioRing, _ count: Int, hostTime: UInt64 = 1) -> [Float] {
        var left = [Float](repeating: -9, count: count), right = [Float](repeating: -9, count: count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                ring.read(left: l.baseAddress!, right: r.baseAddress!, count: count, hostTime: hostTime)
            }
        }
        return left
    }

    private func write(_ ring: AudioRing, _ values: [Float]) {
        values.withUnsafeBufferPointer { v in
            _ = ring.write(left: v.baseAddress!, right: v.baseAddress!, count: values.count)
        }
    }

    func testRingFadesInAfterAFlush() {
        let ring = AudioRing(capacity: 1024)
        ring.flush(toTimelineFrame: 4800, rate: 1, generation: 3)
        write(ring, [Float](repeating: 1, count: 300))
        let out = read(ring, 300, hostTime: 77)
        XCTAssertEqual(out[0], 1 / 257)
        XCTAssertEqual(out[255], 256 / 257)
        XCTAssertEqual(out[256], 1)
        let clock = ring.takeClock()
        XCTAssertEqual(clock, AudioRing.Clock(generation: 3, timelineFrame: 4800, hostTime: 77, rate: 1))
        XCTAssertNil(ring.takeClock())
    }

    func testRingFlushKeepsAFadedTail() {
        let ring = AudioRing(capacity: 1024)
        ring.flush(toTimelineFrame: 0, rate: 1, generation: 0)
        write(ring, [Float](repeating: 1, count: 600))
        _ = read(ring, 300)
        ring.flush(toTimelineFrame: 96_000, rate: -2, generation: 1)
        XCTAssertEqual(ring.buffered, 256)
        let tail = read(ring, 256)
        XCTAssertEqual(tail[0], 256 / 257)
        XCTAssertEqual(tail[255], 1 / 257)
        write(ring, [Float](repeating: 1, count: 10))
        _ = read(ring, 10)
        // The clock counts from the flush point at the new rate.
        XCTAssertEqual(ring.takeClock()?.timelineFrame, 96_000)
    }

    func testRingUnderrunFadesOutAndZeroes() {
        let ring = AudioRing(capacity: 1024)
        ring.flush(toTimelineFrame: 0, rate: 1, generation: 0)
        write(ring, [Float](repeating: 1, count: 400))
        _ = read(ring, 300)
        let out = read(ring, 200)
        // Only 100 frames were left: they fade out over all 100.
        XCTAssertEqual(out[0], 100 / 101)
        XCTAssertEqual(out[99], 1 / 101)
        XCTAssertEqual(out[100], 0)
        XCTAssertEqual(out[199], 0)
        write(ring, [Float](repeating: 1, count: 4))
        XCTAssertEqual(read(ring, 1)[0], 1 / 257)
    }

    func testRingTruncateReturnsWhereTheKeptAudioEnds() {
        let ring = AudioRing(capacity: 4096)
        ring.flush(toTimelineFrame: 1000, rate: 1, generation: 0)
        write(ring, (0..<3000).map { Float($0) })
        let kept = ring.truncate(keeping: 1920, savingTail: 256)
        XCTAssertEqual(kept.timelineFrame, 2920)
        XCTAssertEqual(kept.tailLeft.first, 1920)
        XCTAssertEqual(kept.tailLeft.count, 256)
        XCTAssertEqual(ring.buffered, 1920)
    }

    // MARK: Mixing a file

    private func tone(seconds: Double, value: Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = value } }
        try file.write(from: buffer)
        return url
    }

    func testRendererMixesClipsAtTheirGain() throws {
        let url = try tone(seconds: 2, value: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = AudioMixSource(path: url.path)
        let catalog = MixSourceCatalogHandle()
        let layout = try catalog.layout(segments: [AudioMixSegment(source: source, track: .microphone, fromMs: 500, toMs: 1500, insertAtMs: 0, speed: 1, volume: 0.8)])
        let renderer = MixRenderer(layout: layout, catalog: catalog.catalog)
        renderer.seek(to: 0)
        var left = [Float](repeating: 0, count: 48_000), right = [Float](repeating: 0, count: 48_000)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(left: l.baseAddress!, right: r.baseAddress!, count: 48_000)
            }
        }
        XCTAssertNil(renderer.failure)
        XCTAssertEqual(left[0], 0.5 * 0.8 * (0.5 / 240), accuracy: 1e-6)
        XCTAssertEqual(left[24_000], 0.4, accuracy: 1e-6)
        XCTAssertEqual(right[47_999], 0.5 * 0.8 * (0.5 / 240), accuracy: 1e-6)
    }

    func testPreviewCrossfadesToANewMix() throws {
        let url = try tone(seconds: 3, value: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = AudioMixSource(path: url.path)
        let catalog = MixSourceCatalogHandle()
        func layout(_ volume: Double) throws -> MixLayout {
            try catalog.layout(segments: [AudioMixSegment(source: source, track: .microphone, fromMs: 0, toMs: nil, insertAtMs: 0, speed: 1, volume: volume)])
        }
        let preview = PreviewPlayer(layout: try layout(1), catalog: catalog.catalog)
        preview.request(timeMs: 1000, changed: (0, 3000), hostMs: 0)
        var left = [Float](repeating: 0, count: 480), right = [Float](repeating: 0, count: 480)
        func render(_ hostMs: Double) {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    preview.renderVoices(left: l.baseAddress!, right: r.baseAddress!, count: 480, hostMs: hostMs)
                }
            }
        }
        render(1)
        // Faded in over 480 frames.
        XCTAssertEqual(left[0], 0.5 / 480, accuracy: 1e-6)
        XCTAssertEqual(left[479], 0.5, accuracy: 1e-5)
        preview.setLayout(try layout(0.5))
        render(2)
        // Halfway through the 960-frame crossfade the two voices weigh the same.
        XCTAssertEqual(left[479], 0.375, accuracy: 1e-4)
        render(3)
        XCTAssertEqual(left[479], 0.25, accuracy: 1e-4)
        // The same stretch again while audible only extends the hold.
        preview.request(timeMs: 1000, changed: (0, 3000), hostMs: 10)
        render(11)
        XCTAssertEqual(left[479], 0.25, accuracy: 1e-4)
    }

    func testStretcherPlaysAtSpeed() throws {
        var produced = 0
        let stretcher = try TimeStretcher(speed: 2, algorithm: .current) { left, right, count in
            for i in 0..<count {
                left[i] = sin(Float(produced + i) * 0.05)
                right[i] = left[i]
            }
            produced += count
        }
        var left = [Float](repeating: 0, count: 4800), right = [Float](repeating: 0, count: 4800)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                stretcher.skip(stretcher.latencyFrames)
                stretcher.render(left: l.baseAddress!, right: r.baseAddress!, count: 4800)
            }
        }
        XCTAssertGreaterThan(left.map(abs).max() ?? 0, 0.1)
        XCTAssertGreaterThan(produced, 2 * 4800)
    }

    func testScrubSnippetPlaysTheMixAtThePlayhead() throws {
        let url = try tone(seconds: 3, value: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = MixSourceCatalogHandle()
        let layout = try catalog.layout(segments: [AudioMixSegment(source: AudioMixSource(path: url.path), track: .microphone, fromMs: 0, toMs: nil, insertAtMs: 0, speed: 1, volume: 1)])
        let renderer = MixRenderer(layout: layout, catalog: catalog.catalog)
        let scrub = ScrubPlayer(cache: MixBlockCache(renderer: renderer))
        scrub.add(timeMs: 1500, hostMs: 0)
        XCTAssertEqual(scrub.head?.direction, 1)
        var left = [Float](repeating: 0, count: 256), right = [Float](repeating: 0, count: 256)
        var peaks: [Float] = []
        for block in 0..<24 {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    scrub.render(left: l.baseAddress!, right: r.baseAddress!, count: 256, hostMs: Double(block) * 256 / 48)
                }
            }
            peaks.append(left.map(abs).max() ?? 0)
        }
        // A 100 ms snippet at full gain, then silence.
        XCTAssertEqual(peaks[5], 0.5, accuracy: 0.05)
        XCTAssertEqual(peaks[23], 0)
        XCTAssertFalse(scrub.isActive(atHostMs: 1000))
    }
}
