import AVFoundation
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// How far the engine's audio is from the player's picture over a minute of playback, with
/// and with the player's rate nudged every tick so the picture follows the audio; runs only with REGRAVA_BENCH=1.
struct AudioSyncBenchmark {
    private final class Clocks: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: LiveAudioPlayer.Clock?
        func set(_ clock: LiveAudioPlayer.Clock) { lock.withLock { latest = clock } }
        func get() -> LiveAudioPlayer.Clock? { lock.withLock { latest } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_BENCH"] == "1"), arguments: [false, true])
    @MainActor
    func audioAgainstPicture(chasing: Bool) async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["REGRAVA_SYNC_SECONDS"] ?? "") ?? 60
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        chunk.frameLength = 48_000
        for _ in 0..<Int(seconds + 5) { try file.write(from: chunk) }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        while item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
        let clocks = Clocks()
        let engine = LiveAudioPlayer(onClock: { clocks.set($0) }, onFailure: { print("audio failure:", $0) })
        defer { engine.close() }
        engine.setSegments(try engine.catalog.layout(segments: [AudioMixSegment(source: AudioMixSource(path: url.path), track: .microphone, fromMs: 0, insertAtMs: 0, speed: 1, volume: 1)]))
        try await Task.sleep(for: .milliseconds(300))

        func heard(at now: Double) -> Double? {
            guard let clock = clocks.get(), now - clock.hostTimeMs <= 500 else { return nil }
            return clock.timeMs + (now - clock.hostTimeMs) * clock.rate
        }
        player.rate = 1
        engine.setTransport(LiveAudioPlayer.Transport(isPlaying: true, timeMs: 0, rate: 1, generation: 1))
        var samples: [(t: Double, offset: Double)] = []
        let start = HostClock.nowMs
        var last = start
        while HostClock.nowMs - start < seconds * 1000 {
            try await Task.sleep(for: .milliseconds(16))
            let now = HostClock.nowMs
            let picture = CMTimebaseGetTime(item.timebase!).seconds * 1000
            guard let audio = heard(at: now) else { last = now; continue }

            if picture > 0 { samples.append((now - start, audio - picture)) }
            if chasing {
                player.rate = Float(PlaybackClockChase.playerRate(rate: 1, deltaMs: now - last, errorMs: audio - picture))
            }
            last = now
        }
        player.pause()
        func median(_ part: ArraySlice<(t: Double, offset: Double)>) -> Double { part.map(\.offset).sorted()[part.count / 2] }
        let tenth = max(samples.count / 10, 1)
        print("chasing=\(chasing) audio − picture (ms) over \(Int(seconds)) s: first 10% median=\(median(samples.prefix(tenth))) last 10% median=\(median(samples.suffix(tenth))) min=\(samples.map(\.offset).min()!) max=\(samples.map(\.offset).max()!)")
    }
}
