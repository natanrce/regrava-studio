import Foundation
import Testing
@testable import RegravaCore

@Suite struct ExternalDeviceTests {
    @Test func oldRecordingsAreDisplayRecordings() throws {
        let json = #"{"videoSize":{"width":100,"height":100},"durationMs":1000}"#
        let info = try JSONDecoder().decode(RecordingInfo.self, from: Data(json.utf8))
        #expect(info.mode == .display && info.externalDevice == nil && !info.isExternalDeviceMode)
    }

    @Test func deviceAudioHasItsOwnMuteAndVolume() {
        var audio = AudioConfig()
        audio.muteExternalDeviceAudio = true
        #expect(audio.isMuted(.externalDevice) && !audio.isMuted(.microphone))
        let slice = Slice(sourceStartMs: 0, sourceEndMs: 100, externalDeviceAudioVolume: 0.4)
        #expect(slice.volume(for: .externalDevice) == 0.4)
    }

    @Test func deviceRecordingsGetNoAutomaticZooms() {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1206, height: 2622), pointPixelScale: 1, durationMs: 10_000, fps: 60, mode: .externalDevice), mouseEvents: [
            MouseEvent(kind: .down, timeMs: 1000, position: Vec2(100, 100)), MouseEvent(kind: .up, timeMs: 1100, position: Vec2(100, 100)),
        ])
        p.regenerateAutomaticZooms()
        #expect(p.zooms.isEmpty)
    }
}
