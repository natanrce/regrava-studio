import Foundation

/// The recent playhead positions of a scrub, and where the playhead is heading.
public struct ScrubMotion: Sendable {
    public struct Sample: Equatable, Sendable {
        public var timeMs: Double
        public var hostMs: Double
    }

    /// The playhead's estimated position and speed (timeline ms per host ms).
    public struct Estimate: Equatable, Sendable {
        public var timeMs: Double
        public var rate: Double
        /// The last sample is recent: the speed is not decaying yet.
        public var isFresh: Bool
    }

    /// A pause longer than this starts a new gesture.
    public static let gestureGapMs = 250.0
    public static let sampleCount = 8

    public private(set) var samples: [Sample] = []

    public init() {}

    /// Adds a position; true when it starts a new gesture.
    @discardableResult
    public mutating func add(timeMs: Double, hostMs: Double) -> Bool {
        var startsGesture = false
        if samples.isEmpty || hostMs - samples[samples.count - 1].hostMs > Self.gestureGapMs {
            startsGesture = true
            samples = []
        }
        samples.append(Sample(timeMs: timeMs, hostMs: hostMs))
        if samples.count > Self.sampleCount { samples.removeFirst(samples.count - Self.sampleCount) }
        return startsGesture
    }

    /// The median gap between samples, 4…125 ms (16 ms with fewer than two samples).
    public var typicalGapMs: Double {
        guard samples.count >= 2 else { return 16 }
        let gaps = zip(samples.dropFirst(), samples).map { $0.hostMs - $1.hostMs }.sorted()
        let median = max(gaps[gaps.count / 2], 4)
        return median < 125 ? median : 125
    }

    /// The speed fitted over the last 2.5 gaps (at least 60 ms), decaying once the samples stop.
    public func estimate(atHostMs hostMs: Double) -> Estimate? {
        guard let last = samples.last else { return nil }
        let window = max(typicalGapMs * 2.5, 60)
        let cutoff = last.hostMs - window
        let recent = samples.filter { !(cutoff > $0.hostMs) }
        var rate = 0.0
        if recent.count > 1 {
            let n = Double(recent.count)
            let meanHost = recent.reduce(0) { $0 + $1.hostMs } / n
            let meanTime = recent.reduce(0) { $0 + $1.timeMs } / n
            let covariance = recent.reduce(0) { $0 + ($1.timeMs - meanTime) * ($1.hostMs - meanHost) }
            let variance = recent.reduce(0) { $0 + ($1.hostMs - meanHost) * ($1.hostMs - meanHost) }
            if variance > 0 { rate = covariance / variance }
        }
        let elapsed = hostMs - last.hostMs
        let age = elapsed >= 0 ? elapsed : 0
        let freshFor = max(typicalGapMs * 2.5, 40)
        var isFresh = true
        if age > freshFor {
            rate *= exp((age - freshFor) / -30)
            isFresh = false
        }
        let gap = typicalGapMs
        let ahead = gap < age ? gap : age
        return Estimate(timeMs: last.timeMs + rate * ahead, rate: rate, isFresh: isFresh)
    }
}

/// The scrub voice's playback rate, chasing the playhead.
public struct ScrubRate: Sendable {
    public var rate: Double

    public init(rate: Double = 0) { self.rate = rate }

    /// Moves toward the speed that closes `errorMs` (playhead minus voice) in 80 ms, ±4×,
    /// with a 25 ms time constant; toward 0 once the motion is stale or reverses.
    public mutating func step(errorMs: Double, motion: ScrubMotion.Estimate, elapsedMs: Double) -> Double {
        var target = 0.0
        if motion.isFresh {
            let wanted = errorMs / 80 + motion.rate
            let opposes = abs(motion.rate) > 0.02 && motion.rate.sign != wanted.sign
            if !opposes {
                let low = max(wanted, -4)
                target = low < 4 ? low : 4
            }
        }
        rate = rate + (1 - exp(elapsedMs / -25)) * (target - rate)
        return rate
    }
}

/// The scrub voice's position and direction, as the decision logic sees it.
public struct ScrubHeadState: Equatable, Sendable {
    public var direction: Double
    public var positionFrames: Double

    public init(direction: Double, positionFrames: Double) {
        self.direction = direction
        self.positionFrames = positionFrames
    }
}

/// When the scrub voice starts, moves and how loud it plays.
public struct ScrubControl: Sendable {
    /// A new gesture plays this long at normal speed first.
    public static let snippetFrames: Int64 = 4800
    /// A jump of more than this restarts the voice at the playhead.
    public static let jumpMs = 400.0
    /// The voice falls this far behind a moving playhead before it jumps ahead.
    public static let lagMs = -50.0
    /// Slowest voice speed.
    public static let minimumSpeed = 0.1
    /// Below this the scrub is silent; full gain from `stillRate + fadeRange`.
    public static let stillRate = 0.02
    public static let fadeRange = 0.08

    public var motion = ScrubMotion()
    public var rate = ScrubRate()
    /// What is left of a new gesture's snippet.
    public var snippetFramesLeft: Int64 = 0

    public init() {}

    /// A new playhead position. `startVoice(at:direction:speed:)` starts a voice.
    public mutating func add(timeMs: Double, hostMs: Double, head: ScrubHeadState?, startVoice: (Double, Double, Double) -> Void) {
        let startsGesture = motion.add(timeMs: timeMs, hostMs: hostMs)
        let frame = Double(MixFormat.frames(seconds: max(timeMs, 0) / 1000))
        if startsGesture {
            snippetFramesLeft = Self.snippetFrames
            rate.rate = 1
            startVoice(frame, 1, 1)
        } else if let head, abs(frame - head.positionFrames) / MixFormat.sampleRate * 1000 > Self.jumpMs {
            startVoice(frame, head.direction, max(abs(rate.rate), Self.minimumSpeed))
        }
    }

    /// The rate and gain of the next `elapsedMs` of output. `head()` reads the current voice.
    public mutating func decide(hostMs: Double, elapsedMs: Double, head: () -> ScrubHeadState?, startVoice: (Double, Double, Double) -> Void) -> (rate: Double, gain: Double) {
        guard let estimate = motion.estimate(atHostMs: hostMs), var current = head() else { return (0, 0) }
        let isMoving = estimate.isFresh && abs(estimate.rate) > Self.stillRate
        if snippetFramesLeft > 0 && !isMoving {
            snippetFramesLeft -= MixFormat.frames(seconds: elapsedMs / 1000)
            let gain = snippetFramesLeft < 1 ? 0.0 : 1.0
            rate.rate = gain
            return (1, gain)
        }
        snippetFramesLeft = 0
        if isMoving {
            let lead = estimate.timeMs + current.positionFrames / -MixFormat.sampleRate * 1000
            let signedLead = estimate.rate < 0 ? -lead : lead
            if signedLead < Self.lagMs {
                rate.rate = estimate.rate
                let frame = Double(MixFormat.frames(seconds: estimate.timeMs / 1000))
                startVoice(frame, current.direction, max(abs(estimate.rate), Self.minimumSpeed))
                guard let restarted = head() else { return (0, 0) }
                current = restarted
            }
        }
        let errorMs = estimate.timeMs + current.positionFrames / -MixFormat.sampleRate * 1000
        let next = rate.step(errorMs: errorMs, motion: estimate, elapsedMs: elapsedMs)
        let direction = next < 0 ? -1.0 : 1.0
        let speed = abs(next)
        if speed >= Self.stillRate && direction != current.direction {
            startVoice(current.positionFrames, direction, max(speed, Self.minimumSpeed))
        }
        let x = (speed - Self.stillRate) / Self.fadeRange
        let t = x >= 0 ? min(x, 1) : 0
        return (next, t * t * (3 - (t + t)))
    }
}
