import Foundation
import Testing
@testable import RegravaCore

@Suite struct DeviceFrameTests {
    private func project(_ w: Double, _ h: Double) -> Project {
        Project(recording: RecordingInfo(videoSize: Size2(width: w, height: h), pointPixelScale: 1, durationMs: 1000, fps: 60, mode: .externalDevice), mouseEvents: [])
    }

    @Test func matchesByAspect() {
        #expect(DeviceFrames.catalog.count == 46)
        #expect(project(1206, 2622).resolvedDeviceFrame?.key == "iPhone 18 Pro Max Black")
        #expect(project(1179, 2556).resolvedDeviceFrame?.key == "iPhone 14 Pro Max Deep Purple")
        #expect(project(1170, 2532).resolvedDeviceFrame?.key == "iPhone 14 Midnight")
        #expect(project(1668, 2420).resolvedDeviceFrame?.key == "iPad Air 4")
        #expect(project(2420, 1668).resolvedDeviceFrame?.key == "iPad Air 5th Gen Horizontal Space Gray")
        #expect(project(2622, 1206).resolvedDeviceFrame == nil)
    }

    @Test func perfectAndFlexibleLists() {
        let p = project(1206, 2622)
        let perfect = p.deviceFrameChoices(perfect: true).filter { !$0.colors.isEmpty }.map(\.name)
        #expect(perfect == ["iPhone 18 Pro Max", "iPhone 18 Pro", "iPhone 16 Plus", "iPhone 15 Pro Max", "iPhone 15 Plus", "iPhone 15"])
        // 22 with colours (shown in the panel) among 26 within 0.1.
        #expect(p.deviceFrameChoices(perfect: false).filter { !$0.colors.isEmpty }.count == 22)
    }

    @Test func savedKeyWinsAndScreenRecordingsHaveNone() {
        var p = project(1206, 2622)
        p.device.frameKey = "iPhone 16 Pro Desert"
        #expect(p.resolvedDeviceFrame?.key == "iPhone 16 Pro Desert")
        p.device.enableMockup = false
        #expect(p.activeDeviceFrame == nil && p.resolvedDeviceFrame != nil)
        let screen = Project(recording: RecordingInfo(videoSize: Size2(width: 1206, height: 2622), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        #expect(screen.resolvedDeviceFrame == nil)
    }

    @Test func bodyShapeDefaults() throws {
        let air = try #require(DeviceFrames.lookup("iPad Air 4"))
        #expect(abs(air.device.bodyRadius - 45.9 * 1.04) < 1e-9)
        #expect(air.device.roundness == 0)
        // No frameBorderRadius: screen radius + min(screenX, screenY), × 1.04.
        let pro = try #require(DeviceFrames.lookup("iPhone 12 Pro"))
        #expect(abs(pro.device.bodyRadius - (50 + 19) * 1.04) < 1e-9 && pro.device.roundness == 1)
        let x = try #require(DeviceFrames.lookup("MacBook Air"))
        #expect(x.device.bodyInset == 0)
    }
}
