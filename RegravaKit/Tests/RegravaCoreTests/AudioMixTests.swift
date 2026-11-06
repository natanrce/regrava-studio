import XCTest
@testable import RegravaCore

final class AudioMixTests: XCTestCase {
    private let mic = AudioMixSource(path: "/tmp/mic.m4a")
    private let music = AudioMixSource(path: "/tmp/music.m4a")

    private func segment(_ source: AudioMixSource, track: AudioMixTrack = .microphone, from: Double, to: Double?, at: Double, speed: Double = 1, volume: Double = 1, repeatUntil: Double? = nil) -> AudioMixSegment {
        AudioMixSegment(source: source, track: track, fromMs: from, toMs: to, insertAtMs: at, speed: speed, volume: volume, repeatUntilMs: repeatUntil)
    }

    func testFramesRoundToNearest() {
        XCTAssertEqual(MixFormat.frames(seconds: 0.5), 24_000)
        XCTAssertEqual(MixFormat.frames(seconds: 1.0 / 96_000), 1)
        XCTAssertEqual(MixFormat.frames(seconds: -1.0 / 96_000), -1)
    }

    func testCutAtSpeed() {
        let cuts = MixLayout.cuts(of: segment(mic, from: 1000, to: 3000, at: 500, speed: 2), sourceDurationSeconds: 10)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].sourceStart, 1)
        XCTAssertEqual(cuts[0].startFrame, 24_000)
        XCTAssertEqual(cuts[0].frameCount, 48_000)
    }

    func testCutBeforeZeroStartsLater() {
        let cuts = MixLayout.cuts(of: segment(mic, from: 0, to: 1000, at: -250), sourceDurationSeconds: 10)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].sourceStart, 0.25)
        XCTAssertEqual(cuts[0].startFrame, 0)
        XCTAssertEqual(cuts[0].frameCount, 36_000)
    }

    func testCutEndsAtSourceEnd() {
        let cuts = MixLayout.cuts(of: segment(mic, from: 1000, to: nil, at: 0), sourceDurationSeconds: 3)
        XCTAssertEqual(cuts[0].frameCount, 96_000)
        XCTAssertTrue(MixLayout.cuts(of: segment(mic, from: 4000, to: 5000, at: 0), sourceDurationSeconds: 3).isEmpty)
    }

    func testRepeatedCuts() {
        let cuts = MixLayout.cuts(of: segment(music, track: .backgroundMusic, from: 0, to: nil, at: 0, repeatUntil: 5000), sourceDurationSeconds: 2)
        XCTAssertEqual(cuts.map(\.startFrame), [0, 96_000, 192_000])
        XCTAssertEqual(cuts.map(\.frameCount), [96_000, 96_000, 48_000])
        XCTAssertEqual(cuts.map(\.sourceStart), [0, 0, 0])
    }

    func testEdgeFadesInsideTheSource() throws {
        let layout = try MixLayout(segments: [segment(mic, from: 1000, to: 2000, at: 0)], durationsSeconds: [mic: 10])
        let clip = try XCTUnwrap(layout.clips.first)
        XCTAssertEqual(clip.rampInFrames, 240)
        XCTAssertEqual(clip.startVolume, 0)
        XCTAssertEqual(clip.fadeOutFrames, 240)
        XCTAssertEqual(layout.frameCount, 48_000)
    }

    func testNoFadesAtTheSourceEdges() throws {
        let layout = try MixLayout(segments: [segment(mic, from: 0, to: nil, at: 0, volume: 0.5)], durationsSeconds: [mic: 2])
        let clip = try XCTUnwrap(layout.clips.first)
        XCTAssertEqual(clip.rampInFrames, 0)
        XCTAssertEqual(clip.startVolume, 0.5)
        XCTAssertEqual(clip.fadeOutFrames, 0)
    }

    func testContinuationRampsBetweenVolumes() throws {
        let layout = try MixLayout(segments: [
            segment(mic, from: 0, to: 1000, at: 0, volume: 1),
            segment(mic, from: 1000, to: 2000, at: 1000, volume: 0.5),
        ], durationsSeconds: [mic: 10])
        XCTAssertEqual(layout.clips.count, 2)
        let a = layout.clips[0], b = layout.clips[1]
        XCTAssertEqual(a.rampInFrames, 0)
        XCTAssertEqual(a.fadeOutFrames, 0)
        XCTAssertEqual(b.startVolume, 1)
        XCTAssertEqual(b.rampInFrames, 96)
        XCTAssertEqual(b.fadeOutFrames, 240)
    }

    func testContinuationAtTheSameVolumeHasNoRamp() throws {
        let layout = try MixLayout(segments: [
            segment(mic, from: 0, to: 1000, at: 0),
            segment(mic, from: 1000, to: 2000, at: 1000.5),
        ], durationsSeconds: [mic: 10])
        XCTAssertEqual(layout.clips[1].rampInFrames, 0)
        XCTAssertEqual(layout.clips[1].startVolume, 1)
    }

    func testClicksNeverJoin() throws {
        let click = AudioMixSource(path: "/tmp/click.wav")
        let layout = try MixLayout(segments: [
            segment(click, track: .mouseClick, from: 100, to: 200, at: 0),
            segment(click, track: .mouseClick, from: 200, to: 300, at: 100),
        ], durationsSeconds: [click: 1])
        XCTAssertEqual(layout.clips.map(\.rampInFrames), [240, 240])
        XCTAssertEqual(layout.clips.map(\.fadeOutFrames), [240, 240])
    }

    func testOverlapTrimsUpToThirtyPercent() throws {
        let layout = try MixLayout(segments: [
            segment(mic, from: 0, to: 1000, at: 0),
            segment(mic, from: 5000, to: 6000, at: 500),
        ], durationsSeconds: [mic: 10])
        let b = layout.clips[1]
        XCTAssertEqual(b.startFrame, 38_400)
        XCTAssertEqual(b.frameCount, 33_600)
        XCTAssertEqual(b.sourceStartSeconds, 5.3, accuracy: 1e-12)
    }

    func testRampsAreHalfTheClipAtMost() throws {
        let layout = try MixLayout(segments: [segment(mic, from: 1000, to: 1002, at: 0)], durationsSeconds: [mic: 10])
        XCTAssertEqual(layout.clips[0].frameCount, 96)
        XCTAssertEqual(layout.clips[0].rampInFrames, 48)
        XCTAssertEqual(layout.clips[0].fadeOutFrames, 48)
    }

    func testClipGainPerFrame() {
        let clip = MixClip(source: mic, track: .microphone, sourceStartSeconds: 1, speed: 1, startFrame: 0, frameCount: 1000, volume: 1, startVolume: 0, rampInFrames: 240, fadeOutFrames: 240)
        XCTAssertEqual(clip.gain(atLocalFrame: 0), 0.5 / 240)
        XCTAssertEqual(clip.gain(atLocalFrame: 239), 239.5 / 240)
        XCTAssertEqual(clip.gain(atLocalFrame: 500), 1)
        XCTAssertEqual(clip.gain(atLocalFrame: 760), 239.5 / 240)
        XCTAssertEqual(clip.gain(atLocalFrame: 999), 0.5 / 240)
    }

    func testSkipsSilentAndOutOfRangeSpeeds() throws {
        let layout = try MixLayout(segments: [
            segment(mic, from: 0, to: 1000, at: 0, volume: 0),
            segment(mic, from: 0, to: 1000, at: 0, speed: 40),
        ], durationsSeconds: [mic: 10])
        XCTAssertTrue(layout.clips.isEmpty)
        XCTAssertEqual(layout.frameCount, 0)
    }

    func testInvalidSegmentsThrow() {
        XCTAssertThrowsError(try MixLayout(segments: [segment(mic, from: 0, to: 1, at: 0, speed: 0)], durationsSeconds: [mic: 1]))
        XCTAssertThrowsError(try MixLayout(segments: [segment(mic, from: 0, to: 1, at: 0, volume: 1.5)], durationsSeconds: [mic: 1]))
        XCTAssertThrowsError(try MixLayout(segments: [segment(mic, from: 0, to: 1, at: 0)], durationsSeconds: [:]))
    }

    func testClipsSortedByStartAcrossTracks() throws {
        let layout = try MixLayout(segments: [
            segment(music, track: .backgroundMusic, from: 0, to: nil, at: 0),
            segment(mic, from: 0, to: 1000, at: 2000),
            segment(mic, from: 0, to: 1000, at: 100),
        ], durationsSeconds: [mic: 10, music: 1])
        XCTAssertEqual(layout.clips.map(\.startFrame), [0, 4800, 96_000])
    }

    func testProjectSegmentsFollowTheClips() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 10_000, fps: 30, audioSources: [.microphone, .systemAudio]), mouseEvents: [])
        project.slices = [
            Slice(sourceStartMs: 0, sourceEndMs: 4000),
            Slice(sourceStartMs: 6000, sourceEndMs: 10_000, timeScale: 0.5),
        ]
        project.slices[1].volume = 0.5
        project.audio.muteSystemAudio = true
        let segments = project.audioMixSegments(sources: AudioMixSources(recorded: [.microphone: mic, .systemAudio: music], clickSounds: nil, backgroundAudio: nil))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].insertAtMs, 0)
        XCTAssertEqual(segments[0].fromMs, 0)
        XCTAssertEqual(segments[0].toMs, 4000)
        XCTAssertEqual(segments[1].fromMs, 6000)
        XCTAssertEqual(segments[1].insertAtMs, 4000)
        XCTAssertEqual(segments[1].speed, 2)
        XCTAssertEqual(segments[1].volume, 0.5)
    }

    func testBackgroundRepeatsToTheEnd() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 10_000, fps: 30, audioSources: []), mouseEvents: [])
        project.audio.backgroundAudioFileName = "music.m4a"
        project.audio.backgroundAudioVolume = 0.2
        let segments = project.audioMixSegments(sources: AudioMixSources(recorded: [:], clickSounds: nil, backgroundAudio: music))
        XCTAssertEqual(segments, [AudioMixSegment(source: music, track: .backgroundMusic, fromMs: 0, insertAtMs: 0, speed: 1, volume: 0.2, repeatUntilMs: 10_000)])
    }
}
