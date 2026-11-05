import AVFoundation
import Foundation

/// One stream of samples, read once, handed in order to several writer inputs: every output of
/// an export gets the same rendered frames without rendering them again.
///
/// A sample stays held until every input has taken it. The inputs that ask first read the next
/// sample for everyone, at most `maxHeld` samples ahead of the slowest input.
final class ExportSampleFanOut: @unchecked Sendable {
    private let condition = NSCondition()
    private let read: () -> CMSampleBuffer?
    private let maxHeld: Int
    /// Samples read and not yet taken by every input; `held[0]` is sample number `firstHeld`.
    private var held: [CMSampleBuffer] = []
    private var firstHeld = 0
    /// The number of the next sample each input takes; `Int.max` once it has left.
    private var cursors: [Int]
    private var isReading = false
    private var ended = false

    /// `read` returns the next sample to hand out, or nil at the end of the stream.
    init(consumers: Int, maxHeld: Int = 1, read: @escaping () -> CMSampleBuffer?) {
        precondition(consumers > 0 && maxHeld > 0)
        self.read = read
        self.maxHeld = maxHeld
        cursors = Array(repeating: 0, count: consumers)
    }

    /// The next sample for `consumer`, or nil at the end. Blocks while the sample is still being
    /// read, or while the slowest input holds `maxHeld` samples back.
    func next(for consumer: Int) -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            let index = cursors[consumer]
            if index < firstHeld + held.count {
                let sample = held[index - firstHeld]
                cursors[consumer] = index + 1
                release()
                return sample
            }
            if ended { return nil }
            if !isReading, held.count < maxHeld {
                isReading = true
                condition.unlock()
                let sample = read()
                condition.lock()
                isReading = false
                if let sample { held.append(sample) } else { ended = true }
                condition.broadcast()
                continue
            }
            condition.wait()
        }
    }

    /// `consumer` takes nothing more; the others no longer wait for it.
    func leave(_ consumer: Int) {
        condition.lock()
        cursors[consumer] = .max
        release()
        condition.unlock()
    }

    /// Drops the samples every input has taken and wakes whoever waits for room.
    private func release() {
        let slowest = cursors.min() ?? .max
        let taken = min(max(slowest - firstHeld, 0), held.count)
        if taken > 0 {
            held.removeFirst(taken)
            firstHeld += taken
        }
        condition.broadcast()
    }
}
