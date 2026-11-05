import AVFoundation
import Foundation
import Testing
@testable import RegravaRender

/// A timing-only sample buffer at `index` / 30 s.
private func sample(_ index: Int) -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30), decodeTimeStamp: .invalid
    )
    var buffer: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
        sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
    )
    return buffer!
}

/// Counts the reads and how far ahead of the slowest consumer they got.
private final class Source: @unchecked Sendable {
    let lock = NSLock()
    let count: Int
    var reads = 0
    init(count: Int) { self.count = count }

    func read() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard reads < count else { return nil }
        reads += 1
        return sample(reads - 1)
    }
}

private final class Reported: @unchecked Sendable {
    var values: [Double] = []
}

struct ExportFanOutTests {
    private static func index(_ buffer: CMSampleBuffer) -> Int {
        Int(CMSampleBufferGetPresentationTimeStamp(buffer).value)
    }

    @Test func everyConsumerGetsEverySampleInOrderFromOneRead() async {
        let source = Source(count: 200)
        let fanOut = ExportSampleFanOut(consumers: 2, read: source.read)
        let seen = await withTaskGroup(of: [Int].self) { group in
            for consumer in 0..<2 {
                group.addTask {
                    var indices: [Int] = []
                    while let buffer = fanOut.next(for: consumer) {
                        indices.append(Self.index(buffer))
                        if consumer == 1, indices.count % 7 == 0 { usleep(200) }
                    }
                    return indices
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(seen.count == 2)
        for indices in seen { #expect(indices == Array(0..<200)) }
        #expect(source.reads == 200)
    }

    @Test func aConsumerThatLeavesNoLongerHoldsTheOthersBack() {
        let source = Source(count: 10)
        let fanOut = ExportSampleFanOut(consumers: 2, read: source.read)
        #expect(fanOut.next(for: 0).map(Self.index) == 0)
        fanOut.leave(1)
        var rest: [Int] = []
        while let buffer = fanOut.next(for: 0) { rest.append(Self.index(buffer)) }
        #expect(rest == Array(1..<10))
    }

    /// The leading consumer waits while the slowest still holds `maxHeld` samples back.
    @Test func readsStayWithinTheHeldSamples() async throws {
        let source = Source(count: 50)
        let fanOut = ExportSampleFanOut(consumers: 2, maxHeld: 1, read: source.read)
        #expect(fanOut.next(for: 0).map(Self.index) == 0)
        let leader = Task.detached { fanOut.next(for: 0).map(Self.index) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.reads == 1)
        #expect(fanOut.next(for: 1).map(Self.index) == 0)
        #expect(await leader.value == 1)
        #expect(source.reads == 2)
    }

    @Test func progressIsTheSlowestOutputOnceEachHasAFrame() {
        let reported = Reported()
        let progress = ExportOutputProgress(outputs: 2) { reported.values.append($0) }
        progress.record(0.5, output: 0)
        progress.record(0.2, output: 1)
        progress.record(0.9, output: 0)
        progress.record(1.0, output: 1)
        #expect(reported.values == [0.2, 0.2, 0.9])
        let single = Reported()
        ExportOutputProgress(outputs: 1) { single.values.append($0) }.record(0.3, output: 0)
        #expect(single.values == [0.3])
    }
}
