import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct DeviceFrameRenderTests {
    @Test func wrapsTheRecordingInTheDevice() throws {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1206, height: 2622), pointPixelScale: 1, durationMs: 2000, fps: 60, mode: .externalDevice), mouseEvents: [], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.style.background.kind = .color
        project.style.background.color = RGBA(1, 1, 1)
        let frame = try #require(project.activeDeviceFrame)
        #expect(DeviceFrameArt.url(for: frame.key) != nil)
        let layout = CanvasLayout(project: project)
        let source = CIImage(color: CIColor(red: 0.1, green: 0.5, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1206, height: 2622))
        let cameraFrame = CameraTrack(project: project).frame(at: 500)
        let image = FrameCompositor(project: project, layout: layout, cursors: nil).compose(source: source, frame: cameraFrame)
        if let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] {
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: dir).appendingPathComponent("device-frame.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // The body keeps the device's aspect.
        let body = cameraFrame.screenRect
        #expect(abs(body.width / body.height - frame.device.width / frame.device.height) < 0.01)
        // The middle of the body is the video.
        var p = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: body.midX, y: layout.canvas.height - body.midY, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(p[2] > 180 && p[0] < 80, "\(p)")
    }
}
