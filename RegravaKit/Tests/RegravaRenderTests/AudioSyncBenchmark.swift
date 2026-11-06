import AVFoundation
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// How far the engine's audio is from the player's picture while both play a project from
/// the start; runs only with REGRAVA_SYNC_PROJECT set to a project bundle.
struct AudioSyncBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_SYNC_PROJECT"] != nil))
    func audioAgainstPicture() async throws {
        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REGRAVA_SYNC_PROJECT"]!)
        let project = try ProjectStore.load(from: bundle)
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: video), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundle))
        let item = AVPlayerItem(asset: media.asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        while item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
        await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

        final class Clocks: @unchecked Sendable {
            let lock = NSLock()
            var latest: LiveAudioPlayer.Clock?
        }
        let clocks = Clocks()
        let engine = LiveAudioPlayer(onClock: { clock in
            clocks.lock.lock()
            clocks.latest = clock
            clocks.lock.unlock()
        }, onFailure: { print("audio failure:", $0) })
        defer { engine.close() }
        var recorded: [AudioSource: AudioMixSource] = [:]
        for (index, source) in project.recording.audioSources.enumerated() { recorded[source] = AudioMixSource(path: video.path, audioTrack: index) }
        let segments = project.audioMixSegments(sources: AudioMixSources(recorded: recorded, clickSounds: nil, backgroundAudio: nil))
        engine.setSegments(try engine.catalog.layout(segments: segments))
        try await Task.sleep(for: .milliseconds(300))

        // As the editor starts playing: the player's rate, then the transport.
        player.rate = 1
        engine.setTransport(LiveAudioPlayer.Transport(isPlaying: true, timeMs: 0, rate: 1, generation: 1))
        var offsets: [Double] = []
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            clocks.lock.lock()
            let clock = clocks.latest
            clocks.lock.unlock()
            guard let clock, let timebase = item.timebase else { continue }
            let before = HostClock.nowMs
            let picture = CMTimebaseGetTime(timebase).seconds * 1000
            let now = (before + HostClock.nowMs) / 2
            let heard = clock.timeMs + (now - clock.hostTimeMs) * clock.rate
            if picture > 0 { offsets.append(heard - picture) }
        }
        player.pause()
        let sorted = offsets.sorted()
        print("audio − picture (ms): n=\(offsets.count) median=\(sorted[sorted.count / 2]) min=\(sorted.first!) max=\(sorted.last!) first=\(offsets.prefix(5)) last=\(offsets.suffix(5))")
    }
}
