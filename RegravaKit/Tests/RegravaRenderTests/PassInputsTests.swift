import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// A camera moving between layouts with every layer on at once (cursor and screen trails, a
/// click, captions, shortcuts, a mask, the cut-out camera with its shadow, the loupe) must
/// leave the background as it is: no pass may read a layer's edge past what it drew.
struct PassInputsTests {
    private static func buffer(_ width: Int, _ height: Int, seed: Double) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        // Bright, varied content up to the edges: a wrong read past them shows on the background.
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(translationX: seed, y: seed))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CanvasCompositor.context.render(noise, to: buffer!)
        return buffer!
    }

    private static func project() throws -> Project {
        let json = TrailInputsTests.projectJSON.replacingOccurrences(of: #""type":"camera-overlay""#, with: #""type":"cutout-camera""#)
        var project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        project.cursor.clickEffect = ClickEffect(type: .ripple)
        project.captions.enableShortcuts = true
        project.keystrokes = [
            Keystroke(kind: .down, timeMs: 1300, character: "k", activeModifiers: [.command, .shift]),
            Keystroke(kind: .up, timeMs: 1400, character: "k", activeModifiers: [.command, .shift]),
        ]
        return project
    }

    /// Words of one caption line, all shown at 1500 ms.
    private static let words = "isto deve continuar igual mesmo com muitas palavras na mesma linha".split(separator: " ").enumerated().map {
        TranscriptWord(index: $0.offset, startMs: 900 + Double($0.offset) * 40, endMs: 2500, text: String($0.element))
    }

    private struct Rendered {
        var pixels: [UInt8]
        var bytesPerRow: Int
    }

    private static func render(_ image: CIImage, size: CGSize) throws -> Rendered {
        let output = buffer(Int(size.width), Int(size.height), seed: 0)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = CanvasCompositor.sRGB
        let task = try CanvasCompositor.context.startTask(toRender: image, from: CGRect(origin: .zero, size: size), to: destination, at: .zero)
        _ = try task.waitUntilCompleted()
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(output)
        let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        return Rendered(pixels: Array(UnsafeBufferPointer(start: base, count: row * Int(size.height))), bytesPerRow: row)
    }

    /// Largest difference of the background's top and left margins, in 8-bit steps.
    private static func marginDifference(_ a: Rendered, _ b: Rendered, size: CGSize, margin: Int) -> Int {
        var worst = 0
        let width = Int(size.width), height = Int(size.height)
        func compare(_ x: Int, _ y: Int) {
            let i = y * a.bytesPerRow + x * 4
            for c in 0..<3 { worst = max(worst, abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c]))) }
        }
        for y in 0..<margin { for x in 0..<width { compare(x, y) } }
        for y in margin..<height { for x in 0..<margin { compare(x, y) } }
        return worst
    }

    @Test func cameraTransitionWithEveryLayerLeavesTheBackgroundAlone() throws {
        let project = try Self.project()
        let track = CameraTrack(project: project, fps: 60)
        let size = CGSize(width: 3130, height: 2160)
        let scale = size.width / track.layout.canvas.width
        let compositor = FrameCompositor(project: project, layout: track.layout, cursors: CursorLibrary.arrowOnly(), transcript: Self.words, fps: 60, outputScale: scale)
        let source = CIImage(cvPixelBuffer: Self.buffer(3024, 1964, seed: 0))
        let camera = CIImage(cvPixelBuffer: Self.buffer(1920, 1080, seed: 50))

        var plain = track.frame(at: 1500)
        plain.cameraRect = nil
        plain.cursor = Vec2(1500, 1000)
        plain.previousCursor = plain.cursor
        plain.previousScreenRect = plain.screenRect
        plain.previousCameraRect = nil
        // The loupe shades the whole stage a little: the reference has it too.
        plain.loupe = LoupeFrame(center: Vec2(0.5, 0.5), radius: 0.15, zoom: 2, bevelRatio: 0.2, chromaticAberration: 0.5, shadowAlpha: 0, presence: 1)

        var frame = plain
        // The screen and a fading cursor trailing to the right.
        var before = plain.screenRect
        before.x += 40
        frame.previousScreenRect = before
        frame.cursorOpacity = 0.6
        frame.cursorFadeBlurRadius = 3
        frame.previousCursor = Vec2(1900, 1000)
        frame.clicks = [CursorClick(ageMs: 200, position: Vec2(1500, 1000)), CursorClick(ageMs: 350, position: Vec2(900, 700))]
        frame.mask = MaskFrame(bounds01: Rect2(x: 0.1, y: 0.2, width: 0.3, height: 0.2), borderRadius01: 0.01, type: .sensitiveData, highlightOpacity: 0.5, active: true, opacity: 1)
        // The camera half cut out, fading in, moving and growing from the corner.
        let screen = plain.screenRect
        frame.cameraRect = Rect2(x: screen.x + screen.width * 0.55, y: screen.y + screen.height * 0.45, width: screen.width * 0.4, height: screen.height * 0.5)
        frame.previousCameraRect = Rect2(x: screen.x + screen.width * 0.7, y: screen.y + screen.height * 0.65, width: screen.width * 0.25, height: screen.height * 0.3)
        frame.cameraOpacity = 0.8
        frame.cameraCutout01 = 0.5
        frame.cameraCornerRadius = 40
        frame.cameraSizeFactor = 1

        func composed(_ f: CameraFrame, camera: CIImage?) -> CIImage {
            compositor.compose(source: source, camera: camera, frame: f, quality: .export).cropped(to: CGRect(origin: .zero, size: size))
        }
        let reference = try Self.render(composed(plain, camera: nil), size: size)
        let busy = try Self.render(composed(frame, camera: camera), size: size)

        // Top and left of the screen only the background shows (padding 0.1 of the canvas).
        let margin = Int(size.height * 0.05)
        #expect(Self.marginDifference(busy, reference, size: size, margin: margin) <= 2, "background margins changed")
    }
}
