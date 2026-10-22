import AVFoundation
import RegravaRender

/// The recorder's start and end sounds: the start sound plays as recording starts or resumes,
/// and when sound is recorded capture begins once it has played (at most 540 ms), so it isn't
/// recorded; the end sound plays once a pause or the end stopped recording.
@MainActor
enum RecordingSounds {
    private static var players: [AVAudioPlayer] = []

    /// Plays the start sound; returns after it, capped at 540 ms, when sound is being recorded.
    static func playBegin(recordsSound: Bool) async {
        guard let duration = play(BundledSounds.recordingBegin) else { return }
        guard recordsSound else { return }
        try? await Task.sleep(nanoseconds: UInt64(min(duration, 0.54) * 1_000_000_000))
    }

    static func playEnd() {
        _ = play(BundledSounds.recordingEnd)
    }

    /// Returns the sound's length.
    @discardableResult
    private static func play(_ url: URL?) -> TimeInterval? {
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        players.removeAll { !$0.isPlaying }
        players.append(player)
        player.play()
        return player.duration
    }
}
