import CoreImage
import CoreText
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct CaptionRenderTests {
    @Test func burnsCaptionsIntoTheFrame() throws {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 6000, fps: 30), mouseEvents: [], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.style.shadow.intensity = 0
        let text = ["Welcome", " to", " the", " screen", " recording."]
        let words = text.enumerated().map { TranscriptWord(index: $0, startMs: 1000 + Double($0) * 300, endMs: 1280 + Double($0) * 300, text: $1) }
        let layout = CanvasLayout(project: project)
        let compositor = FrameCompositor(project: project, layout: layout, cursors: nil, transcript: words)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let track = CameraTrack(project: project)
        let image = compositor.compose(source: source, frame: track.frame(at: 2300))
        if let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] {
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: dir).appendingPathComponent("captions.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // The box sits at the bottom centre of the padded canvas: dark pixels there.
        let canvas = layout.canvas
        let padded = canvas.padByRatio(-0.1)
        var p = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: canvas.width / 2, y: canvas.height - padded.endY + 4, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(p[0] < 40 && p[1] < 40 && p[2] < 40, "\(p)")
        // Without captions enabled nothing is drawn there.
        project.captions.enableTranscript = false
        let plain = FrameCompositor(project: project, layout: layout, cursors: nil, transcript: words).compose(source: source, frame: track.frame(at: 2300))
        CIContext().render(plain, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: canvas.width / 2, y: canvas.height - padded.endY + 4, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(p[2] > 100)
    }
}

struct CaptionMotionBlurTests {
    @Test func movingWordsTrailWithMotionBlur() throws {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 6000, fps: 30), mouseEvents: [], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.captions.wordEntrance = .slideIn
        let words = ["Welcome", " to", " the"].enumerated().map { TranscriptWord(index: $0, startMs: 1000 + Double($0) * 300, endMs: 1280 + Double($0) * 300, text: $1) }
        let canvas = Rect2(x: 0, y: 0, width: 1920, height: 1080)
        let renderer = try #require(CaptionRenderer(project: project, words: words, canvas: canvas, fps: 60))
        let base = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        func pixels(_ image: CIImage) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
            CIContext().render(image, toBitmap: &p, rowBytes: 1920 * 4, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), format: .RGBA8, colorSpace: nil)
            return p
        }
        // The second word slides in at 1300 ms: blurred and sharp differ; at rest they match.
        #expect(pixels(renderer.draw(over: base, atPlayback: 1340, motionBlurStrength: 1)) != pixels(renderer.draw(over: base, atPlayback: 1340)))
        #expect(pixels(renderer.draw(over: base, atPlayback: 4500, motionBlurStrength: 1)) == pixels(renderer.draw(over: base, atPlayback: 4500)))
    }
}

struct CaptionFontTests {
    @Test func bundlesTheCaptionFonts() {
        #expect((CaptionRenderer.bundledFont("InstrumentSerif-Regular", size: 20).map { CTFontCopyFamilyName($0) as String }) == "Instrument Serif")
        #expect((CaptionRenderer.bundledFont("GeistMono-Variable", size: 20).map { CTFontCopyFamilyName($0) as String }) == "Geist Mono")
    }
}
