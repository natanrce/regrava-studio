import Foundation

/// The files a project's mix plays from.
public struct AudioMixSources: Sendable {
    /// Each recorded source present in the recording.
    public var recorded: [AudioSource: AudioMixSource]
    /// The click set's files, when click sounds are on.
    public var clickSounds: [ClickSoundKind: AudioMixSource]?
    /// The background audio file, when one is set and found.
    public var backgroundAudio: AudioMixSource?

    public init(recorded: [AudioSource: AudioMixSource], clickSounds: [ClickSoundKind: AudioMixSource]?, backgroundAudio: AudioMixSource?) {
        self.recorded = recorded
        self.clickSounds = clickSounds
        self.backgroundAudio = backgroundAudio
    }
}

public extension Project {
    /// The segments the editor plays: every unmuted recorded source through each clip at its
    /// volume, the click sounds at their events, and the background audio repeated to the end.
    func audioMixSegments(sources: AudioMixSources) -> [AudioMixSegment] {
        let playbackDurationMs = resolver.playbackDurationMs
        let links = resolver.links
        var out: [AudioMixSegment] = []
        let session = (fromMs: 0.0, toMs: recording.durationMs)
        for (source, track) in [(AudioSource.microphone, AudioMixTrack.microphone), (.systemAudio, .systemAudio), (.externalDevice, .externalDevice)] {
            guard !audio.isMuted(source), let file = sources.recorded[source] else { continue }
            for (slice, link) in zip(slices, links) {
                let volume = slice.volume(for: source)
                guard volume > 0 else { continue }
                guard let range = Self.intersection((slice.sourceStartMs, slice.sourceEndMs), session) else { continue }
                guard let placed = Self.place(slice: slice, link: link, sourceRangeMs: range, mediaZeroSourceMs: session.fromMs, mediaSpeed: 1) else { continue }
                out.append(AudioMixSegment(source: file, track: track, fromMs: placed.fromMs, toMs: placed.toMs, insertAtMs: placed.insertAtMs, speed: placed.speed, volume: volume))
            }
        }
        if let clicks = sources.clickSounds, audio.clickSoundEffectVolume > 0 {
            for click in plannedClickSounds {
                guard let file = clicks[click.kind] else { continue }
                out.append(AudioMixSegment(source: file, track: .mouseClick, fromMs: 0, insertAtMs: click.playbackTimeMs, speed: 1, volume: audio.clickSoundEffectVolume))
            }
        }
        if let file = sources.backgroundAudio, audio.backgroundAudioFileName != nil, !audio.muteBackgroundAudio, audio.backgroundAudioVolume > 0, playbackDurationMs > 0 {
            out.append(AudioMixSegment(source: file, track: .backgroundMusic, fromMs: 0, insertAtMs: 0, speed: 1, volume: audio.backgroundAudioVolume, repeatUntilMs: playbackDurationMs))
        }
        return out
    }

    private static func intersection(_ a: (Double, Double), _ b: (fromMs: Double, toMs: Double)) -> (fromMs: Double, toMs: Double)? {
        let from = max(a.0, b.fromMs), to = min(a.1, b.toMs)
        return to > from ? (from, to) : nil
    }

    /// A clip's part of a source range, in the media's time and in playback time.
    private static func place(slice: Slice, link: TimeResolver.Link, sourceRangeMs: (fromMs: Double, toMs: Double), mediaZeroSourceMs: Double, mediaSpeed: Double) -> (fromMs: Double, toMs: Double, insertAtMs: Double, speed: Double)? {
        guard slice.speed.isFinite, slice.speed > 0 else { return nil }
        return (
            (sourceRangeMs.fromMs - mediaZeroSourceMs) * mediaSpeed,
            (sourceRangeMs.toMs - mediaZeroSourceMs) * mediaSpeed,
            link.playbackStartMs + (sourceRangeMs.fromMs - slice.sourceStartMs) * slice.timeScale,
            slice.speed * mediaSpeed
        )
    }
}
