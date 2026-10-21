import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct CameraMotionBlurTests {
    @Test func movingCameraLeavesATrail() throws {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 2000, fps: 60), mouseEvents: [], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.style.shadow.intensity = 0
        project.style.background.kind = .color
        project.style.background.color = RGBA(1, 1, 1)
        project.animation.motionBlurAmount = 1
        let layout = CanvasLayout(project: project)
        let screen = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let camera = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        var frame = CameraTrack(project: project).frame(at: 0)
        frame.cameraRect = Rect2(x: 600, y: 300, width: 200, height: 200)
        frame.previousCameraRect = Rect2(x: 400, y: 300, width: 200, height: 200)
        frame.cameraOpacity = 1
        let compositor = FrameCompositor(project: project, layout: layout, cursors: nil)
        let image = compositor.compose(source: screen, camera: camera, frame: frame)
        func red(_ x: Double, _ yTop: Double) -> UInt8 {
            var p = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: layout.canvas.height - yTop - 1, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return p[0]
        }
        // Between where it was and where it is, the camera is smeared: neither white nor black.
        let mid = red(500, 400)
        #expect(mid > 30 && mid < 225, "\(mid)")
        // Without motion blur that spot is the background.
        project.animation.motionBlurAmount = 0
        let still = FrameCompositor(project: project, layout: layout, cursors: nil).compose(source: screen, camera: camera, frame: frame)
        var p = [UInt8](repeating: 0, count: 4)
        CIContext().render(still, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: 500, y: layout.canvas.height - 401, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(p[0] > 240)
    }
}
