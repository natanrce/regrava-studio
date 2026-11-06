import Foundation

/// The mix's sample format: 48 kHz stereo.
public enum MixFormat {
    public static let sampleRate = 48_000.0
    public static let channelCount = 2

    /// Seconds to the nearest frame.
    public static func frames(seconds: Double) -> Int64 { Int64((seconds * sampleRate).rounded()) }
    public static func seconds(frames: Int64) -> Double { Double(frames) / sampleRate }
}

/// The mix's tracks, in mixing order.
public enum AudioMixTrack: String, CaseIterable, Sendable, Hashable {
    case microphone
    case systemAudio
    case externalDevice
    case voiceover
    case backgroundMusic
    case mouseClick
}

/// An audio file of the mix and which of its audio tracks plays.
public struct AudioMixSource: Hashable, Sendable {
    public var path: String
    public var audioTrack: Int

    public init(path: String, audioTrack: Int = 0) {
        self.path = path
        self.audioTrack = audioTrack
    }
}

/// A stretch of a source placed on the timeline: `fromMs…toMs` of the source (to its end when
/// `toMs` is nil) at `insertAtMs`, played at `speed`, repeated until `repeatUntilMs` when set.
public struct AudioMixSegment: Hashable, Sendable {
    public var source: AudioMixSource
    public var track: AudioMixTrack
    public var fromMs: Double
    public var toMs: Double?
    public var insertAtMs: Double
    public var speed: Double
    public var volume: Double
    public var repeatUntilMs: Double?

    public init(source: AudioMixSource, track: AudioMixTrack, fromMs: Double, toMs: Double? = nil, insertAtMs: Double, speed: Double, volume: Double, repeatUntilMs: Double? = nil) {
        self.source = source
        self.track = track
        self.fromMs = fromMs
        self.toMs = toMs
        self.insertAtMs = insertAtMs
        self.speed = speed
        self.volume = volume
        self.repeatUntilMs = repeatUntilMs
    }
}

public enum MixError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidSegment(String)
    case source(path: String, message: String)

    public var description: String {
        switch self {
        case .invalidSegment(let message): return "Invalid audio segment: \(message)"
        case .source(let path, let message): return "\(path): \(message)"
        }
    }
}

/// One stretch of a source in the mix, in output frames, with its gain ramps.
public struct MixClip: Hashable, Sendable {
    public var source: AudioMixSource
    public var track: AudioMixTrack
    public var sourceStartSeconds: Double
    public var speed: Double
    public var startFrame: Int64
    public var frameCount: Int64
    public var volume: Float
    /// Gain at the first frame, ramped to `volume` over `rampInFrames`.
    public var startVolume: Float
    public var rampInFrames: Int64
    public var fadeOutFrames: Int64

    public var endFrame: Int64 { startFrame + frameCount }

    public init(source: AudioMixSource, track: AudioMixTrack, sourceStartSeconds: Double, speed: Double, startFrame: Int64, frameCount: Int64, volume: Float, startVolume: Float, rampInFrames: Int64, fadeOutFrames: Int64) {
        self.source = source
        self.track = track
        self.sourceStartSeconds = sourceStartSeconds
        self.speed = speed
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.volume = volume
        self.startVolume = startVolume
        self.rampInFrames = rampInFrames
        self.fadeOutFrames = fadeOutFrames
    }

    /// The gain of the clip's frame `local` (0 = its first frame).
    public func gain(atLocalFrame local: Int64) -> Float {
        var g = volume
        if local < rampInFrames {
            g = startVolume + (volume - startVolume) * ((Float(local) + 0.5) / Float(rampInFrames))
        }
        if frameCount - local <= fadeOutFrames {
            g = ((Float(frameCount - local) - 0.5) / Float(fadeOutFrames)) * g
        }
        return g
    }
}

/// The segments laid out as clips, sorted by start frame.
public struct MixLayout: Hashable, Sendable {
    public var clips: [MixClip]
    public var frameCount: Int64

    public static let empty = MixLayout(clips: [], frameCount: 0)

    public init(clips: [MixClip], frameCount: Int64) {
        self.clips = clips
        self.frameCount = frameCount
    }

    /// Fades of a clip that starts or ends inside its source.
    static let edgeFadeFrames: Int64 = 240
    /// Ramp between two continuing clips at different volumes.
    static let continuationRampFrames: Int64 = 96
    /// Clips this close (frames, and 1 ms of source) continue each other.
    static let continuationToleranceFrames: Int64 = 48
    static let continuationToleranceSeconds = 0.001

    struct Placed {
        var segment: AudioMixSegment
        var index: Int
        var durationSeconds: Double
        var sourceStart: Double
        var startFrame: Int64
        var frameCount: Int64
    }

    /// `durationsSeconds`: each source's length.
    public init(segments: [AudioMixSegment], durationsSeconds: [AudioMixSource: Double]) throws {
        var placed: [AudioMixTrack: [Placed]] = [:]
        for (index, segment) in segments.enumerated() {
            guard segment.speed > 0, segment.speed.isFinite else { throw MixError.invalidSegment("speed must be greater than 0") }
            if segment.volume < 0 || segment.volume > 1 { throw MixError.invalidSegment("volume must be 0...1") }
            guard let duration = durationsSeconds[segment.source] else { throw MixError.source(path: segment.source.path, message: "not opened") }
            guard segment.volume > 0, segment.speed >= 0.03125, segment.speed <= 32 else { continue }
            for cut in Self.cuts(of: segment, sourceDurationSeconds: duration) {
                placed[segment.track, default: []].append(Placed(
                    segment: segment, index: index, durationSeconds: duration,
                    sourceStart: cut.sourceStart, startFrame: cut.startFrame, frameCount: cut.frameCount
                ))
            }
        }
        var clips: [MixClip] = []
        for track in AudioMixTrack.allCases {
            guard var list = placed[track] else { continue }
            list = Self.stableSorted(list) { a, b in a.startFrame != b.startFrame ? a.startFrame < b.startFrame : a.index < b.index }
            let joins = track != .mouseClick
            if joins { list = Self.trimmingOverlaps(list) }
            clips += Self.clips(from: list, joinsContinuations: joins)
        }
        clips = Self.stableSorted(clips) { $0.startFrame < $1.startFrame }
        self.clips = clips
        frameCount = clips.map(\.endFrame).max() ?? 0
    }

    /// Where a segment lands: once, or repeated until `repeatUntilMs`.
    static func cuts(of segment: AudioMixSegment, sourceDurationSeconds: Double) -> [(sourceStart: Double, startFrame: Int64, frameCount: Int64)] {
        let start = max(segment.fromMs / 1000, 0)
        var end = sourceDurationSeconds
        if let toMs = segment.toMs, sourceDurationSeconds > toMs / 1000 { end = toMs / 1000 }
        guard start < end else { return [] }
        let speed = segment.speed
        let insert = segment.insertAtMs / 1000
        let length = (end - start) / speed
        guard let repeatUntilMs = segment.repeatUntilMs else {
            let a = MixFormat.frames(seconds: insert)
            let b = MixFormat.frames(seconds: insert + length)
            let first: Int64
            if a < 0 {
                guard b >= 1 else { return [] }
                first = 0
            } else {
                guard b > a else { return [] }
                first = a
            }
            return [(start + speed * (Double(first - a) / MixFormat.sampleRate), first, b - first)]
        }
        let until = repeatUntilMs / 1000
        var out: [(sourceStart: Double, startFrame: Int64, frameCount: Int64)] = []
        var t = insert
        while t < until {
            let piece = min(until - t, length)
            let a = MixFormat.frames(seconds: t)
            let b = MixFormat.frames(seconds: t + piece)
            if a < 0 {
                if b > 0 { out.append((start + speed * (Double(-a) / MixFormat.sampleRate), 0, b)) }
            } else if a < b {
                out.append((start + speed * (0 / MixFormat.sampleRate), a, b - a))
            }
            t = length + t
        }
        return out
    }

    /// A clip starting inside the previous one loses up to 30% of its start.
    static func trimmingOverlaps(_ placed: [Placed]) -> [Placed] {
        var out: [Placed] = []
        for var p in placed {
            if let last = out.last {
                let lastEnd = last.startFrame + last.frameCount
                if p.startFrame < lastEnd {
                    let trim = min(Int64(Double(p.frameCount) * 0.3), lastEnd - p.startFrame)
                    p.startFrame += trim
                    p.frameCount -= trim
                    p.sourceStart = p.sourceStart + (Double(trim) / MixFormat.sampleRate) * p.segment.speed
                }
            }
            if p.frameCount >= 1 { out.append(p) }
        }
        return out
    }

    static func clips(from placed: [Placed], joinsContinuations: Bool) -> [MixClip] {
        func continues(_ a: Placed, into b: Placed) -> Bool {
            guard a.segment.source == b.segment.source, a.segment.speed == b.segment.speed else { return false }
            guard abs(b.startFrame - (a.startFrame + a.frameCount)) <= continuationToleranceFrames else { return false }
            return abs(b.sourceStart - (a.sourceStart + a.segment.speed * (Double(a.frameCount) / MixFormat.sampleRate))) <= continuationToleranceSeconds
        }
        var out: [MixClip] = []
        for (i, p) in placed.enumerated() {
            let volume = Float(p.segment.volume)
            let previous = i > 0 ? placed[i - 1] : nil
            let next = i + 1 < placed.count ? placed[i + 1] : nil
            let continuesPrevious = joinsContinuations && previous.map { continues($0, into: p) } == true
            let continuesNext = joinsContinuations && next.map { continues(p, into: $0) } == true
            var rampIn: Int64
            var startVolume: Float
            if continuesPrevious, let previous {
                startVolume = Float(previous.segment.volume)
                rampIn = startVolume != volume ? continuationRampFrames : 0
            } else if p.sourceStart <= continuationToleranceSeconds {
                rampIn = 0
                startVolume = volume
            } else {
                rampIn = edgeFadeFrames
                startVolume = 0
            }
            var fadeOut: Int64 = 0
            if !continuesNext {
                let sourceEnd = p.sourceStart + p.segment.speed * (Double(p.frameCount) / MixFormat.sampleRate)
                fadeOut = p.durationSeconds - continuationToleranceSeconds <= sourceEnd ? 0 : edgeFadeFrames
            }
            let half = p.frameCount / 2
            rampIn = min(rampIn, half)
            fadeOut = min(fadeOut, half)
            out.append(MixClip(
                source: p.segment.source, track: p.segment.track, sourceStartSeconds: p.sourceStart, speed: p.segment.speed,
                startFrame: p.startFrame, frameCount: p.frameCount, volume: volume, startVolume: startVolume,
                rampInFrames: rampIn, fadeOutFrames: fadeOut
            ))
        }
        return out
    }

    private static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
