import Foundation
import os

/// The audio queued for the output: written by the mixing thread, read by the output. It
/// remembers which timeline frame its audio starts at, so the output can report what it plays.
final class AudioRing: @unchecked Sendable {
    /// When a timeline frame was played (output host time) and at what rate.
    struct Clock: Equatable {
        var generation: Int
        var timelineFrame: Double
        var hostTime: UInt64
        var rate: Double
    }

    /// Queued audio cut away fades out over up to this many frames; audio after a gap fades in.
    static let flushFadeFrames = 256
    static let resumeFadeFrames = 256
    /// The output's last frames before running dry fade out over up to this many frames.
    static let underrunFadeFrames = 128

    let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let lock: OSAllocatedUnfairLock<Void>
    private var readIndex = 0
    private var writeIndex = 0
    /// Ring index of `anchorTimelineFrame`.
    private var anchorIndex = 0
    private var anchorTimelineFrame = 0.0
    private var rate = 1.0
    private var generation = 0
    /// Audio from this index on fades in.
    private var resumeIndex = 0
    private var clock: Clock?

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        lock = OSAllocatedUnfairLock()
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    private func slot(_ index: Int) -> Int { index % capacity }

    var buffered: Int { lock.withLockUnchecked { writeIndex - readIndex } }
    var free: Int { lock.withLockUnchecked { capacity - (writeIndex - readIndex) } }

    /// Keeps the next 256 frames, faded out, drops the rest; what is written next starts at
    /// `timelineFrame`, moving `rate` frames per frame.
    func flush(toTimelineFrame timelineFrame: Double, rate: Double, generation: Int) {
        lock.withLockUnchecked {
            let tail = min(writeIndex - readIndex, Self.flushFadeFrames)
            for i in 0..<tail {
                let s = slot(readIndex + i)
                let g = Float(tail - i) / Float(tail + 1)
                left[s] = g * left[s]
                right[s] = g * right[s]
            }
            writeIndex = readIndex + tail
            anchorIndex = writeIndex
            anchorTimelineFrame = timelineFrame
            self.rate = rate
            self.generation = generation
            resumeIndex = writeIndex
            clock = nil
        }
    }

    /// Appends up to `count` frames (as many as fit); returns how many.
    @discardableResult
    func write(left source: UnsafePointer<Float>, right sourceRight: UnsafePointer<Float>, count: Int) -> Int {
        lock.withLockUnchecked {
            let n = min(count, capacity - (writeIndex - readIndex))
            for i in 0..<n {
                let s = slot(writeIndex + i)
                left[s] = source[i]
                right[s] = sourceRight[i]
            }
            writeIndex += n
            return n
        }
    }

    /// Keeps `keeping` frames of queued audio and drops the rest; returns the timeline frame
    /// the kept audio ends at and up to `savingTail` frames of what was dropped.
    func truncate(keeping: Int, savingTail: Int) -> (timelineFrame: Double, tailLeft: [Float], tailRight: [Float]) {
        lock.withLockUnchecked {
            let keepEnd = min(readIndex + keeping, writeIndex)
            let tailCount = min(writeIndex - keepEnd, savingTail)
            var tailLeft: [Float] = [], tailRight: [Float] = []
            if tailCount > 0 {
                tailLeft = (0..<tailCount).map { left[slot(keepEnd + $0)] }
                tailRight = (0..<tailCount).map { right[slot(keepEnd + $0)] }
            }
            writeIndex = keepEnd
            return (anchorTimelineFrame + rate * Double(keepEnd - anchorIndex), tailLeft, tailRight)
        }
    }

    /// The output's read, at the host time the audio will be heard. Never waits for the lock:
    /// silence when the writer holds it.
    func read(left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>, count: Int, hostTime: UInt64) {
        guard let locked = lock.withLockIfAvailableUnchecked({ readLocked(left: out, right: outRight, count: count, hostTime: hostTime) }) else {
            out.update(repeating: 0, count: count)
            outRight.update(repeating: 0, count: count)
            return
        }
        _ = locked
    }

    private func readLocked(left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>, count: Int, hostTime: UInt64) {
        let available = writeIndex - readIndex
        let n = min(available, count)
        if n >= 1 {
            clock = Clock(generation: generation, timelineFrame: anchorTimelineFrame + rate * Double(readIndex - anchorIndex), hostTime: hostTime, rate: rate)
            for i in 0..<n {
                let index = readIndex + i
                let s = slot(index)
                let sinceResume = index - resumeIndex
                let g: Float = sinceResume >= 0 && sinceResume < Self.resumeFadeFrames ? Float(sinceResume + 1) / Float(Self.resumeFadeFrames + 1) : 1
                out[i] = g * left[s]
                outRight[i] = g * right[s]
            }
        }
        readIndex += max(n, 0)
        if available < count {
            let fade = min(n, Self.underrunFadeFrames)
            for j in 0..<max(fade, 0) {
                let k = n - fade + j
                let g = Float(fade - j) / Float(fade + 1)
                out[k] = g * out[k]
                outRight[k] = g * outRight[k]
            }
            let rest = count - max(n, 0)
            if rest > 0 {
                out.advanced(by: max(n, 0)).update(repeating: 0, count: rest)
                outRight.advanced(by: max(n, 0)).update(repeating: 0, count: rest)
            }
            resumeIndex = readIndex
        }
    }

    /// Takes the last reported clock.
    func takeClock() -> Clock? {
        lock.withLockUnchecked {
            let taken = clock
            clock = nil
            return taken
        }
    }
}
