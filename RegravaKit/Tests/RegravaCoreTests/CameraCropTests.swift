import Foundation
import Testing
@testable import RegravaCore

struct CameraCropTests {
    @Test func opensOnTheStoredCropMirroredForTheEditor() {
        let state = CameraCropState(videoSize: Size2(width: 1920, height: 1080), crop01: Rect2(x: 0.1, y: 0.2, width: 0.5, height: 0.5), mirror: true)
        #expect(abs(state.crop.x - 0.4 * 1920) < 0.001 && abs(state.crop.y - 216) < 0.001)
        let back = state.confirmedCrop01(mirror: true)!
        #expect(abs(back.x - 0.1) < 1e-9 && abs(back.width - 0.5) < 1e-9)
    }

    @Test func enforcesTheMinimumAndKeepsInsideTheFrame() {
        var state = CameraCropState(videoSize: Size2(width: 1280, height: 720), crop01: nil, mirror: false)
        state.setCrop(Rect2(x: 1200, y: 700, width: 50, height: 50))
        #expect(state.crop == Rect2(x: 1080, y: 520, width: 200, height: 200))
        #expect(!state.isTooSmall)
        state.setCrop(Rect2(x: 0, y: 0, width: 50, height: 50), applyConstraints: false)
        #expect(state.isTooSmall)
    }

    @Test func aspectLockDerivesFromTheHeight() {
        var state = CameraCropState(videoSize: Size2(width: 1280, height: 720), crop01: nil, mirror: false)
        state.setForcedAspectRatio(Vec2(1, 1))
        #expect(state.crop == Rect2(x: 0, y: 0, width: 720, height: 720))
        state.setCrop(Rect2(x: 0, y: 0, width: 200, height: 200))
        state.setForcedAspectRatio(Vec2(9, 16))
        #expect(abs(state.crop.width - 112.5) < 1e-9 && state.isTooSmall)
        state.expandToFullSize()
        #expect(state.forcedAspectRatio == nil && state.confirmedCrop01(mirror: false) == nil)
    }
}
