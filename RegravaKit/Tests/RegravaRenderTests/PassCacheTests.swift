import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Pass outputs kept between frames: served when a pass hashes the same, drawn again when
/// anything it reads changed, released after the frames stop.
struct PassCacheTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)

    private static func buffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(bounds.width), Int(bounds.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer!
    }

    private static func fill(_ buffer: CVPixelBuffer, _ value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)) { base[i] = i % 4 == 3 ? 255 : value }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private static func pixels(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: base, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)))
    }

    /// `image` drawn by the frame context; the passes it ran.
    private static func draw(_ image: CIImage, to output: CVPixelBuffer, context: CIContext = CanvasCompositor.context) throws -> Int {
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = CanvasCompositor.sRGB
        return try context.startTask(toRender: image, from: bounds, to: destination, at: .zero).waitUntilCompleted().passCount
    }

    /// A few blurs over a gradient: nothing in them comes from a pixel buffer.
    private static func background(_ shift: Double) -> CIImage {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: shift, y: 0), "inputPoint1": CIVector(x: 640, y: 360),
            "inputColor0": CIColor(red: 0.9, green: 0.2, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.8),
        ])!.outputImage!
        let blurred = gradient.cropped(to: bounds).clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: bounds)
        return blurred.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 3]).cropped(to: bounds)
    }

    @Test func aPassHashingTheSameIsServed() throws {
        let output = Self.buffer()
        // Passes Core Image splits the graph into, and a pass the frame ends itself.
        for (name, pass) in [("passes", { Self.background($0) }), ("ended pass", { RenderPass.ended(Self.background($0)) })] as [(String, (Double) -> CIImage)] {
            let first = try Self.draw(pass(17).applyingFilter("CIColorInvert"), to: output)
            let firstPixels = Self.pixels(output)
            let again = try Self.draw(pass(17).applyingFilter("CIColorInvert"), to: output)
            #expect(again < first, "\(name) served: \(again) passes, drawn: \(first)")
            #expect(Self.pixels(output) == firstPixels)
            // A parameter changed below the pass: drawn again.
            #expect(try Self.draw(pass(18).applyingFilter("CIColorInvert"), to: output) == first, "\(name)")
        }
    }

    @Test func aPixelBufferWrittenAgainIsDrawnAgain() throws {
        let source = Self.buffer(), output = Self.buffer(), reference = Self.buffer()
        let fresh = CIContext(options: [.cacheIntermediates: false])
        func frame(_ image: CIImage) -> CIImage {
            RenderPass.served(image.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: Self.bounds)).applyingFilter("CIColorInvert")
        }
        for value: UInt8 in [40, 200, 90] {
            Self.fill(source, value)
            _ = try Self.draw(frame(CIImage(cvPixelBuffer: source)), to: output)
            _ = try Self.draw(frame(CIImage(cvPixelBuffer: source)), to: reference, context: fresh)
            #expect(Self.pixels(output) == Self.pixels(reference), "buffer filled with \(value)")
        }
        // Drawn on the GPU into the same buffer.
        for gray in [0.25, 0.75] {
            fresh.render(CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: Self.bounds), to: source)
            _ = try Self.draw(frame(CIImage(cvPixelBuffer: source)), to: output)
            _ = try Self.draw(frame(CIImage(cvPixelBuffer: source)), to: reference, context: fresh)
            #expect(Self.pixels(output) == Self.pixels(reference), "buffer drawn \(gray)")
        }
    }

    @Test func aServedFrameMatchesOneDrawnFromScratch() throws {
        let project = try PassInputsTests.project()
        let track = CameraTrack(project: project, fps: 60)
        let size = CGSize(width: 1280, height: 720)
        let compositor = FrameCompositor(project: project, layout: track.layout, cursors: CursorLibrary.arrowOnly(), transcript: PassInputsTests.words, fps: 60, outputScale: size.width / track.layout.canvas.width)
        let screen = PassInputsTests.buffer(3024, 1964, seed: 0)
        let fresh = CIContext(options: [.cacheIntermediates: false])
        func render(_ context: CIContext, timeMs: Double) throws -> [UInt8] {
            let output = PassInputsTests.buffer(Int(size.width), Int(size.height), seed: 0)
            let image = compositor.compose(source: CIImage(cvPixelBuffer: screen), frame: track.frame(at: timeMs), quality: .pausedHigh).cropped(to: CGRect(origin: .zero, size: size))
            let destination = CIRenderDestination(pixelBuffer: output)
            destination.colorSpace = CanvasCompositor.sRGB
            _ = try context.startTask(toRender: image, from: CGRect(origin: .zero, size: size), to: destination, at: .zero).waitUntilCompleted()
            return Self.pixels(output)
        }
        for timeMs in [1000.0, 1500, 1500, 2200, 1500] {
            #expect(try render(CanvasCompositor.context, timeMs: timeMs) == render(fresh, timeMs: timeMs), "at \(timeMs) ms")
        }
    }

    /// A clock and a timer queue driven by hand.
    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 100
        var pending: [(at: TimeInterval, work: @Sendable () -> Void)] = []
        var releases = 0

        func advance(to time: TimeInterval) {
            while let next = pending.min(by: { $0.at < $1.at }), next.at <= time {
                pending.removeAll { $0.at == next.at }
                now = next.at
                next.work()
            }
            now = time
        }
    }

    @Test func keptOutputsAreReleasedFiveSecondsAfterTheLastFrame() {
        let clock = Clock()
        let keepAlive = RenderPass.KeepAlive(now: { clock.now }, schedule: { delay, work in clock.pending.append((clock.now + delay, work)) }, release: { clock.releases += 1 })
        #expect(!keepAlive.isHolding)
        keepAlive.markUsed()
        #expect(keepAlive.isHolding)
        // Frames every second keep it.
        for t in stride(from: 101.0, through: 110, by: 1) {
            clock.advance(to: t)
            keepAlive.markUsed()
        }
        #expect(clock.releases == 0)
        // Idle from 110: still held at 115, released at the first sweep past five seconds.
        clock.advance(to: 115)
        #expect(clock.releases == 0)
        clock.advance(to: 116)
        #expect(clock.releases == 1)
        #expect(!keepAlive.isHolding)
        #expect(clock.pending.isEmpty, "no sweep while nothing is held")
        // A new frame starts sweeping again.
        keepAlive.markUsed()
        clock.advance(to: 123)
        #expect(clock.releases == 2)
    }
}
