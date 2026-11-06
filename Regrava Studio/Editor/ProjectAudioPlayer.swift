import AVFoundation
import Foundation
import RegravaCore
import RegravaRender

/// The editor's audio: plays the project's mix through the live audio engine while the
/// player shows the video. It follows the transport, scrubs while paused when the audio
/// scrubber is on, and previews volume changes.
@MainActor
final class ProjectAudioPlayer {
    /// Mix changes are sent at most this often.
    static let segmentsDelay: Duration = .milliseconds(40)
    /// Right after a transport change its own time counts as heard for this long.
    static let transportGraceMs = 150.0
    /// A clock older than this says nothing anymore.
    static let clockMaxAgeMs = 500.0

    private weak var editor: EditorModel?
    private var player: LiveAudioPlayer?
    private var isMuted = false
    private var transportGeneration = 0
    private var transportSent = (atMs: 0.0, timeMs: 0.0)
    private var sentTransportKey: (isAudible: Bool, rate: Double)?
    private(set) var latestClock: LiveAudioPlayer.Clock?
    private var lastDisplayedTimeMs: Double?

    // Segments: throttled, then laid out one at a time (the newest waiting).
    private var lastSegments: [AudioMixSegment]?
    private var segmentsTask: Task<Void, Never>?
    private var isLayingOut = false
    private var queuedSegments: [AudioMixSegment]?

    func start(editor: EditorModel) {
        guard player == nil else { return }
        self.editor = editor
        let owner = WeakOwner(self)
        let player = LiveAudioPlayer(onClock: { clock in
            Task { @MainActor in owner.value?.receive(clock) }
        }, onFailure: { message in
            NSLog("Audio playback failed: %@", message)
        })
        self.player = player
        setMuted(editor.player.isMuted)
        projectDidChange()
        sendTransport()
    }

    private func receive(_ clock: LiveAudioPlayer.Clock) {
        guard clock.generation == transportGeneration else { return }
        latestClock = clock
    }

    func close() {
        segmentsTask?.cancel()
        player?.close()
        player = nil
    }

    // MARK: Mix

    /// The project or its files changed.
    func projectDidChange() {
        guard player != nil, segmentsTask == nil else { return }
        segmentsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.segmentsDelay)
            guard let self, !Task.isCancelled else { return }
            self.segmentsTask = nil
            self.sendSegmentsNow()
        }
    }

    private func sendSegmentsNow() {
        guard let editor else { return }
        let segments = editor.project.audioMixSegments(sources: editor.audioMixSources)
        guard segments != lastSegments else { return }
        lastSegments = segments
        layOut(segments)
    }

    private func layOut(_ segments: [AudioMixSegment]) {
        guard let player else { return }
        guard !isLayingOut else {
            queuedSegments = segments
            return
        }
        isLayingOut = true
        let catalog = player.catalog
        let owner = WeakOwner(self)
        Task.detached(priority: .userInitiated) {
            let result = Result { try catalog.layout(segments: segments) }
            await MainActor.run { owner.value?.laidOut(result) }
        }
    }

    private func laidOut(_ result: Result<MixLayout, Error>) {
        switch result {
        case .success(let layout): player?.setSegments(layout)
        case .failure(let error): NSLog("Audio player call failed: %@", String(describing: error))
        }
        isLayingOut = false
        if let next = queuedSegments {
            queuedSegments = nil
            layOut(next)
        }
    }

    // MARK: Transport

    private var rate: Double { editor?.effectiveRate ?? 1 }
    private var isAudible: Bool { (editor?.isPlaying ?? false) && rate != 0 }

    /// Playing, paused or a new rate.
    func playbackDidChange() {
        guard player != nil else { return }
        if let sent = sentTransportKey, sent.isAudible == isAudible, sent.rate == rate { return }
        sendTransport()
    }

    /// The playhead was set (not moved by playback).
    func timeDidSet() {
        if isAudible { sendTransport() }
    }

    private func sendTransport() {
        guard let player, let editor else { return }
        transportGeneration += 1
        transportSent = (HostClock.nowMs, editor.currentTimeMs)
        latestClock = nil
        sentTransportKey = (isAudible, rate)
        player.setTransport(LiveAudioPlayer.Transport(isPlaying: isAudible, timeMs: editor.currentTimeMs, rate: rate, generation: transportGeneration))
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.setVolume(muted ? 0 : 1)
    }

    /// The time being heard now, from the engine's clock; nil while unknown.
    var audibleTimeMs: Double? {
        guard isAudible else { return nil }
        let now = HostClock.nowMs
        guard let clock = latestClock else {
            return now - transportSent.atMs < Self.transportGraceMs ? transportSent.timeMs : nil
        }
        let age = now - clock.hostTimeMs
        return age > Self.clockMaxAgeMs ? nil : clock.timeMs + age * clock.rate
    }

    // MARK: Paused

    /// The time shown while paused changed (playhead or hover).
    func displayedTimeDidChange(_ timeMs: Double) {
        let previous = lastDisplayedTimeMs
        lastDisplayedTimeMs = timeMs
        guard previous != timeMs, let player, let editor, !editor.isPlaying, Preferences.shared.playbackAudioScrubber, !isMuted else { return }
        player.scrub(timeMs: timeMs, hostMs: HostClock.nowMs)
    }

    /// Volumes changed inside `changed` (playback ms).
    func previewChange(_ changed: (startMs: Double, endMs: Double)) {
        guard let player, let editor, !editor.isPlaying, !isMuted else { return }
        player.preview(timeMs: editor.currentTimeMs, changed: changed)
    }
}

/// Reaches the player from the engine's threads without keeping it alive.
private final class WeakOwner: @unchecked Sendable {
    weak var value: ProjectAudioPlayer?
    init(_ value: ProjectAudioPlayer) { self.value = value }
}

extension EditorModel {
    /// The files the mix plays: the recording's audio tracks (the microphone from its best
    /// finished render), the click set and the background audio.
    var audioMixSources: AudioMixSources {
        let movie = videoURL.path
        var recorded: [AudioSource: AudioMixSource] = [:]
        for (index, source) in project.recording.audioSources.enumerated() {
            recorded[source] = AudioMixSource(path: movie, audioTrack: index)
        }
        if recorded[.microphone] != nil, let url = MicrophoneRenderer.bestReadyURL(bundle: bundleURL, preset: project.audio.microphoneAudioPreset) {
            recorded[.microphone] = AudioMixSource(path: url.path)
        }
        var clicks: [ClickSoundKind: AudioMixSource]?
        if let set = project.audio.clickSoundEffect {
            clicks = [:]
            for kind in [ClickSoundKind.down, .up, .click] {
                if let url = BundledSounds.click(set, kind) { clicks?[kind] = AudioMixSource(path: url.path) }
            }
        }
        var background: AudioMixSource?
        if let name = project.audio.backgroundAudioFileName {
            let url = ProjectStore.assetsURL(bundle: bundleURL).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { background = AudioMixSource(path: url.path) }
        }
        return AudioMixSources(recorded: recorded, clickSounds: clicks, backgroundAudio: background)
    }

    /// `previewAudioChange`: the changed clips' playback ranges; the one under the playhead,
    /// else the first.
    func previewAudioChange(slices ids: [UUID]) {
        let resolver = project.resolver
        let t = clock.currentTimeMs
        let ranges = ids.compactMap { id in
            project.slices.firstIndex { $0.id == id }.map { (startMs: resolver.links[$0].playbackStartMs, endMs: resolver.links[$0].playbackEndMs) }
        }
        guard let range = ranges.first(where: { $0.startMs <= t && t < $0.endMs }) ?? ranges.first else { return }
        audioPlayer.previewChange(range)
    }
}
