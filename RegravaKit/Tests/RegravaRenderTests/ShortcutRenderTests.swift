import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct ShortcutRenderTests {
    @Test func drawsKeyCapsAtTheBottom() throws {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 6000, fps: 30), mouseEvents: [], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.style.shadow.intensity = 0
        project.keystrokes = [
            Keystroke(kind: .down, timeMs: 1000, character: "$", activeModifiers: [.command, .shift]),
            Keystroke(kind: .up, timeMs: 1100, character: "$", activeModifiers: [.command, .shift]),
            Keystroke(kind: .down, timeMs: 3500, character: " ", activeModifiers: [.option]),
            Keystroke(kind: .down, timeMs: 3600, character: "\u{7F}", activeModifiers: [.option]),
        ]
        project.captions.enableShortcuts = true
        let layout = CanvasLayout(project: project)
        let compositor = FrameCompositor(project: project, layout: layout, cursors: nil)
        let source = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let track = CameraTrack(project: project)
        let image = compositor.compose(source: source, frame: track.frame(at: 1600))
        if let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] {
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: dir).appendingPathComponent("shortcuts.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let later = compositor.compose(source: source, frame: track.frame(at: 4000))
            try CIContext().writePNGRepresentation(of: later, to: URL(fileURLWithPath: dir).appendingPathComponent("shortcuts2.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // The middle key sits at the bottom centre: dark pixels there.
        let canvas = layout.canvas
        var p = [UInt8](repeating: 0, count: 4)
        let y = canvas.height - (canvas.height - canvas.padByRatio(-0.05).y - canvas.height * 0.05)
        CIContext().render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: canvas.width / 2 - 20, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(p[0] < 60 && p[1] < 60 && p[2] < 60, "\(p)")
        // Long after the press nothing is drawn.
        let empty = compositor.compose(source: source, frame: track.frame(at: 5900))
        CIContext().render(empty, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: canvas.width / 2 - 20, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(p[0] > 150, "\(p)")
    }
}

