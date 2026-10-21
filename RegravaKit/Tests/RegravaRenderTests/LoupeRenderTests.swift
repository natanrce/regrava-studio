import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct LoupeRenderTests {
    @Test func lensMagnifiesTheScreen() throws {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 8000, fps: 30), mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(960, 540))], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.zooms = [ZoomRange(startMs: 1000, endMs: 7000, scale: 2, mode: .manual, manualTarget: Vec2(0.5, 0.5), presentation: .loupe)]
        let layout = CanvasLayout(project: project)
        let stripes = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 0.95, green: 0.95, blue: 0.95), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.8),
            "inputWidth": 60, "inputCenter": CIVector(x: 0, y: 0),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let track = CameraTrack(project: project)
        let frame = track.frame(at: 4000)
        #expect(frame.loupe != nil)
        let image = FrameCompositor(project: project, layout: layout, cursors: nil).compose(source: stripes, frame: frame)
        if let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] {
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: dir).appendingPathComponent("loupe.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let entering = FrameCompositor(project: project, layout: layout, cursors: nil).compose(source: stripes, frame: track.frame(at: 1000))
            try CIContext().writePNGRepresentation(of: entering, to: URL(fileURLWithPath: dir).appendingPathComponent("loupe-enter.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // After the loupe the frame is the plain stage again.
        #expect(track.frame(at: 7990 + 0).loupe == nil || track.frame(at: 7990).loupe!.presence < 0.2)
    }
}
