import Foundation
import RegravaCore

/// Plays the mix around a moving playhead while paused: a voice chases it at a pitch-kept
/// speed; a new gesture after a rest plays a short snippet first.
final class ScrubPlayer {
    /// A replaced voice fades out over this many frames.
    static let crossfadeFrames = 480
    static let scratchFrames = 1024

    let cache: MixBlockCache
    private var control = ScrubControl()
    private(set) var head: MixHead?
    private var fading: (head: MixHead, framesLeft: Int, gain: Double)?
    /// The gain the last block ended at.
    private(set) var gain = 0.0
    private var scratchLeft = [Float](repeating: 0, count: ScrubPlayer.scratchFrames)
    private var scratchRight = [Float](repeating: 0, count: ScrubPlayer.scratchFrames)

    init(cache: MixBlockCache) {
        self.cache = cache
    }

    private var headState: ScrubHeadState? {
        head.map { ScrubHeadState(direction: $0.direction, positionFrames: $0.position) }
    }

    func add(timeMs: Double, hostMs: Double) {
        let state = headState
        control.add(timeMs: timeMs, hostMs: hostMs, head: state) { startVoice(at: $0, direction: $1, speed: $2) }
    }

    /// Whether there is anything left to play at `hostMs`.
    func isActive(atHostMs hostMs: Double) -> Bool {
        guard gain <= 0, fading == nil, control.snippetFramesLeft < 1 else { return true }
        return control.motion.estimate(atHostMs: hostMs)?.isFresh == true
    }

    /// Starts a voice at frame `at`; the current one fades out.
    private func startVoice(at frame: Double, direction: Double, speed: Double) {
        if let head, gain > 0 {
            fading = (head, Self.crossfadeFrames, gain)
        }
        gain = 0
        guard let next = try? MixHead(at: frame, direction: direction, speed: speed, cache: cache), let stretcher = next.stretcher else { return }
        let priming = stretcher.latencyFrames + MixHead.primingExtraFrames
        next.position = frame - direction * Double(priming)
        stretcher.skip(priming)
        stretcher.setSpeed(speed)
        head = next
    }

    /// Adds `count` frames of scrub audio (with `hostMs` the time they will be heard) into
    /// zeroed `left` and `right`.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, hostMs: Double) {
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        let elapsedMs = Double(count) / MixFormat.sampleRate * 1000
        let decision = control.decide(hostMs: hostMs, elapsedMs: elapsedMs, head: { headState }) { startVoice(at: $0, direction: $1, speed: $2) }
        renderFadingVoice(into: left, right, count: count)
        guard let head, let stretcher = head.stretcher else { return }
        guard decision.gain > 0 || gain > 0 else { return }
        let speed = max(abs(decision.rate), ScrubControl.minimumSpeed)
        head.speed = speed
        stretcher.setSpeed(speed)
        let from = gain, to = decision.gain
        scratchLeft.withUnsafeMutableBufferPointer { sl in
            scratchRight.withUnsafeMutableBufferPointer { sr in
                stretcher.render(left: sl.baseAddress!, right: sr.baseAddress!, count: count)
                let span = to - from
                for i in 0..<count {
                    let g = Float(from + (span * Double(i + 1)) / Double(count))
                    left[i] += sl[i] * g
                    right[i] += sr[i] * g
                }
            }
        }
        gain = to
    }

    private func renderFadingVoice(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        guard let current = fading, let stretcher = current.head.stretcher else { return }
        let n = min(current.framesLeft, count)
        stretcher.setSpeed(current.head.speed)
        scratchLeft.withUnsafeMutableBufferPointer { sl in
            scratchRight.withUnsafeMutableBufferPointer { sr in
                stretcher.render(left: sl.baseAddress!, right: sr.baseAddress!, count: n)
                let done = Self.crossfadeFrames - current.framesLeft
                for i in 0..<n {
                    let x = min(Double(done + i + 1) / Double(Self.crossfadeFrames), 1)
                    let g = Float(cos(x * Double.pi * 0.5) * current.gain)
                    left[i] += sl[i] * g
                    right[i] += sr[i] * g
                }
            }
        }
        fading = count < current.framesLeft ? (current.head, current.framesLeft - n, current.gain) : nil
    }
}
