import Foundation
import Testing
@testable import RegravaCore

struct ScreenCropTests {
    func project() -> Project {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 2000, height: 1000), pointPixelScale: 2, durationMs: 1000, fps: 60),
                        mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(1500, 500))])
        p.masks = [MaskRange(startMs: 0, endMs: 500, bounds: [Rect2(x: 1100, y: 300, width: 100, height: 50)])]
        return p
    }

    @Test func cropSpaceShiftsEventsAndMasks() {
        var p = project()
        p.crop.rect01 = Rect2(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        #expect(p.croppedVideoSize == Size2(width: 1000, height: 500))
        let space = p.screenCropSpace
        #expect(space.recording.videoSize == Size2(width: 1000, height: 500))
        #expect(space.mouseEvents[0].position == Vec2(500, 250))
        #expect(space.masks[0].bounds[0].x == 100 && space.masks[0].bounds[0].y == 50)
        #expect(space.crop.isFull)
        // The layout sees the cropped aspect.
        #expect(abs(p.stageInfo.sourceSize.width / p.stageInfo.sourceSize.height - 2) < 1e-9)
    }

    @Test func devicesCannotCrop() {
        var p = project()
        p.crop.rect01 = Rect2(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        p.recording.flags = ["ScreenContinuity"]
        #expect(!p.canChangeCrop && p.screenCrop01 == ScreenCropConfig.full)
    }

    @Test func invalidCropDecodesAsFull() throws {
        let json = #"{"rect01":{"x":0,"y":0,"width":0,"height":1}}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ScreenCropConfig.self, from: json).isFull)
    }
}
