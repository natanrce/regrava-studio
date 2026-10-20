import Foundation
import Testing
@testable import RegravaCore

struct CameraSilenceTests {
    @Test func quietWindowsRelativeToTheLoudestBecomeChunks() {
        // 50 ms windows: loud 1 s, quiet 3 s (5% of the loudest), loud 1 s, quiet 0.5 s.
        let rms = Array(repeating: 1.0, count: 20) + Array(repeating: 0.05, count: 60) + Array(repeating: 0.8, count: 20) + Array(repeating: 0.0, count: 10)
        let chunks = SilenceDetection.chunks(windowRMS: rms, durationMs: 5500, minSilenceDurationMs: 2000)
        #expect(chunks == [SilenceChunk(startMs: 1000, endMs: 4000)])
        #expect(SilenceDetection.minimumDurationMs(5049) == 5000)
    }

    @Test func hidesAwayFromTheEdgesOfLongSilences() {
        let chunks = [SilenceChunk(startMs: 1000, endMs: 7000), SilenceChunk(startMs: 9000, endMs: 11_000)]
        #expect(!SilenceDetection.isSilent(chunks, at: 1300, hideDuringSilenceMs: 5000))
        #expect(SilenceDetection.isSilent(chunks, at: 4000, hideDuringSilenceMs: 5000))
        #expect(!SilenceDetection.isSilent(chunks, at: 6700, hideDuringSilenceMs: 5000))
        // Too short for the setting.
        #expect(!SilenceDetection.isSilent(chunks, at: 10_000, hideDuringSilenceMs: 5000))
    }

    @Test func trackHidesTheCameraButNotInFullscreen() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 2, durationMs: 20_000, fps: 60, cameraFileName: "camera.mov", cameraSize: Size2(width: 1280, height: 720)), mouseEvents: [])
        let silence = [SilenceChunk(startMs: 2000, endMs: 12_000)]
        #expect(CameraTrack(project: project, silence: silence).frame(at: 8000).cameraOpacity > 0.99)
        project.camera.hideDuringSilenceMs = 5000
        #expect(CameraTrack(project: project, silence: silence).frame(at: 8000).cameraOpacity < 0.01)
        #expect(CameraTrack(project: project, silence: silence).frame(at: 15_000).cameraOpacity > 0.99)
        project.cameraLayouts = [CameraLayoutRange(startMs: 6000, endMs: 10_000, type: .fullscreenCamera)]
        #expect(CameraTrack(project: project, silence: silence).frame(at: 9000).cameraOpacity > 0.99)
    }
}
