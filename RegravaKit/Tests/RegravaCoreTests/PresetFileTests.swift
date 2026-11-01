import Foundation
import Testing
@testable import RegravaCore

struct PresetFileTests {
    /// A preset's meta.json from the fixture reads into the same settings.
    @Test func readsAPresetMetaFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/preset-meta.json")
        let config = try PresetFile.decode(Data(contentsOf: url))
        #expect(config.cursor.size == 48)
        #expect(config.cursor.set.id == "macos-tahoe")
        #expect(config.style.cornerRadius == 16)
        #expect(config.style.paddingRatio == 0.1)
        #expect(config.style.aspectRatio == nil)
        #expect(config.style.background.systemName == "macOS/san-francisco-dark.jpg")
        #expect(config.style.background.gradientStops.first?.hexString == "#4776e6")
        #expect(config.animation.mouseSpring?.stiffness == 340)
        #expect(config.animation.screenSpring.damping == 12)
        #expect(config.defaultLayout?.cameraOverlay.zoomedScale == 0.8)
        #expect(config.captions?.enableShortcuts == true)
        #expect(config.device?.enableMockup == true)
    }

    /// Written and read back unchanged, in the envelope.
    @Test func roundTrips() throws {
        let project = Project(recording: RecordingInfo(videoSize: Size2(width: 100, height: 100), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        var config = project.presetConfig
        config.style.cornerRadius = 22
        config.style.aspectRatio = 16.0 / 9
        config.processing?.autoMaskFaces = true
        let data = try PresetFile.encode(config, appVersion: "1.0")
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let json = root["json"] as! [String: Any]
        #expect(json["version"] as? String == "4.0.0")
        #expect(((json["projectConfig"] as! [String: Any])["styles"] as! [String: Any])["screenBorderRadius"] as? Double == 22)
        let back = try PresetFile.decode(data)
        #expect(back.style == config.style)
        #expect(back.cursor == config.cursor)
        #expect(back.audio == config.audio)
        #expect(back.processing?.autoMaskFaces == true)
        #expect(back.defaultLayout == config.defaultLayout)
    }

    /// No cursor smoothing is written as null and read back as nil; a missing key means null too.
    @Test func keepsNoCursorSmoothing() throws {
        let project = Project(recording: RecordingInfo(videoSize: Size2(width: 100, height: 100), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        var config = project.presetConfig
        config.animation.mouseSpring = nil
        let data = try PresetFile.encode(config, appVersion: "1.0")
        let json = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["json"] as! [String: Any]
        let animations = (json["projectConfig"] as! [String: Any])["animations"] as! [String: Any]
        #expect(animations["mouseMovementSpring"] is NSNull)
        #expect(try PresetFile.decode(data).animation.mouseSpring == nil)
        let missing = #"{"json":{"version":"4.0.0","projectConfig":{"animations":{}}}}"#.data(using: .utf8)!
        #expect(try PresetFile.decode(missing).animation.mouseSpring == nil)
    }

    /// `cameraConfig.aspectRatio` and `background.blurAmount01` are kept through a save.
    @Test func keepsTheCameraAspectRatioAndBlurAmount() throws {
        var camera = CameraConfig()
        #expect(camera.aspectRatio == 1)
        #expect(camera.background.blurAmount01 == 0)
        camera.aspectRatio = 1.5
        camera.background.blurAmount01 = 0.25
        let project = Project(recording: RecordingInfo(videoSize: Size2(width: 100, height: 100), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        var config = project.presetConfig
        config.camera = camera
        let back = try PresetFile.decode(PresetFile.encode(config, appVersion: "1.0"))
        #expect(back.camera?.aspectRatio == 1.5)
        #expect(back.camera?.background.blurAmount01 == 0.25)
        // Older projects without the keys keep the defaults.
        let old = try JSONDecoder().decode(CameraConfig.self, from: Data(#"{"mirror":true,"background":{"edgeFalloff01":0.4}}"#.utf8))
        #expect(old.aspectRatio == 1)
        #expect(old.background.blurAmount01 == 0)
        #expect(old.background.edgeFalloff01 == 0.4)
    }

    /// The gradient's start and end points and its stop positions are read and written; a
    /// plain list of colours is spread evenly from (0, 0) to (1, 1).
    @Test func keepsGradientPointsAndStopPositions() throws {
        let gradient = BackgroundGradient(start: Vec2(0.5, 0), end: Vec2(0.5, 1), stops: [
            .init(color: RGBA(hex: 0x112233), at: 0.2), .init(color: RGBA(hex: 0x445566), at: 0.9),
        ])
        let project = Project(recording: RecordingInfo(videoSize: Size2(width: 100, height: 100), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        var config = project.presetConfig
        config.style.background.gradient = gradient
        let back = try PresetFile.decode(PresetFile.encode(config, appVersion: "1.0"))
        #expect(back.style.background.gradient == gradient)
        let list = PresetFile.gradient(["#ff0000", "#00ff00", "#0000ff"], .default)
        #expect(list.start == Vec2(0, 0) && list.end == Vec2(1, 1))
        #expect(list.stops.map(\.at) == [0, 0.5, 1])
        // Projects that stored only the colours keep them, evenly spaced.
        let old = try JSONDecoder().decode(BackgroundConfig.self, from: Data(#"{"gradientStops":[{"r":1,"g":0,"b":0,"a":1},{"r":0,"g":0,"b":1,"a":1}]}"#.utf8))
        #expect(old.gradient.stops.map(\.at) == [0, 1])
        #expect(old.gradient.end == Vec2(1, 1))
        // New colours keep the points and are spread evenly.
        var edited = BackgroundConfig(gradient: gradient)
        edited.gradientStops = [RGBA(hex: 0), RGBA(hex: 0xFFFFFF), RGBA(hex: 0x808080)]
        #expect(edited.gradient.start == Vec2(0.5, 0))
        #expect(edited.gradient.stops.map(\.at) == [0, 0.5, 1])
    }

    @Test func rejectsABadVersion() {
        let data = #"{"json":{"version":"x","projectConfig":{}}}"#.data(using: .utf8)!
        #expect(throws: PresetFile.Failure.self) { try PresetFile.decode(data) }
    }
}
