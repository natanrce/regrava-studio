import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RegravaCore
@testable import RegravaRender

/// Preview frame time on a real project at fixed output sizes (REGRAVA_BENCH_PREVIEW=<bundle
/// path>): decode and compose through the video composition, best of three runs.
struct PreviewSizeBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_BENCH_PREVIEW"] != nil))
    func previewFrameTime() async throws {
        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REGRAVA_BENCH_PREVIEW"]!)
        let project = try ProjectStore.load(from: bundle)
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: video), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundle))
        let canvas = project.canvasSize
        for height in [1080.0, 720, 540] {
            let output = Size2(width: (height * canvas.aspectRatio).rounded(), height: height)
            for quality in [RenderQuality.playing, .pausedHigh] {
                let state = RenderState(project: project, cursors: CursorLibrary.arrowOnly(), assetsDirectory: bundle, outputSize: output)
                state.quality = quality
                CompositionFactory.prewarm(state: state, outputSize: output)
                let configuration = try await CompositionFactory.configuration(asset: media.asset, state: state, canvas: canvas, outputSize: output, fps: 60)
                var runs: [Double] = []
                for _ in 0..<3 {
                    let reader = try AVAssetReader(asset: media.asset)
                    let out = AVAssetReaderVideoCompositionOutput(videoTracks: try await media.asset.loadTracks(withMediaType: .video), videoSettings: nil)
                    out.videoComposition = AVVideoComposition(configuration: configuration)
                    reader.add(out)
                    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(project.recording.durationMs / 1000, 6), preferredTimescale: 600))
                    reader.startReading()
                    var count = 0
                    var start = CFAbsoluteTimeGetCurrent()
                    while out.copyNextSampleBuffer() != nil {
                        count += 1
                        if count == 10 { start = CFAbsoluteTimeGetCurrent() }
                    }
                    runs.append((CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(max(count - 10, 1)))
                }
                let sorted = runs.sorted()
                print(String(format: "BENCH preview %.0fx%.0f %@: best %.2f ms/frame, median %.2f", output.width, output.height, "\(quality)", sorted[0], sorted[1]))
            }
        }
    }
}

/// Real-project frames composed at canvas size and scaled, against frames drawn at the output
/// size (REGRAVA_COMPARE_PREVIEW=<bundle path>, REGRAVA_COMPARE_OUT=<folder for the PNGs>).
struct PreviewSizeComparison {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_COMPARE_PREVIEW"] != nil))
    func compareFrames() async throws {
        let env = ProcessInfo.processInfo.environment
        let bundle = URL(fileURLWithPath: env["REGRAVA_COMPARE_PREVIEW"]!)
        let folder = URL(fileURLWithPath: env["REGRAVA_COMPARE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try ProjectStore.load(from: bundle)
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: video), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundle))
        let canvas = project.canvasSize
        let height = Double(env["REGRAVA_COMPARE_HEIGHT"] ?? "720")!
        let output = Size2(width: (height * canvas.aspectRatio).rounded(), height: height)
        func frames(_ state: RenderState, _ name: String) async throws -> [CGImage] {
            state.quality = .pausedHigh
            let configuration = try await CompositionFactory.configuration(asset: media.asset, state: state, canvas: canvas, outputSize: output, fps: 60)
            let generator = AVAssetImageGenerator(asset: media.asset)
            generator.videoComposition = AVVideoComposition(configuration: configuration)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var images: [CGImage] = []
            for t in [1.0, 3, 5, 8, 12] {
                let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                let url = folder.appendingPathComponent("\(name)-\(Int(t))s.png")
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
                images.append(image)
            }
            return images
        }
        let scaled = try await frames(RenderState(project: project, cursors: CursorLibrary.arrowOnly(), assetsDirectory: bundle), "scaled")
        let direct = try await frames(RenderState(project: project, cursors: CursorLibrary.arrowOnly(), assetsDirectory: bundle, outputSize: output), "direct")
        func rgba(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        for (i, (a, b)) in zip(scaled, direct).enumerated() {
            let pa = rgba(a), pb = rgba(b)
            var sum = 0.0, worst = 0, far = 0
            for j in 0..<min(pa.count, pb.count) {
                let d = abs(Int(pa[j]) - Int(pb[j]))
                sum += Double(d)
                worst = max(worst, d)
                if d > 32 { far += 1 }
            }
            print(String(format: "COMPARE frame %d %dx%d: mean %.3f, max %d, over 32: %.3f%%", i, a.width, a.height, sum / Double(pa.count), worst, Double(far) * 100 / Double(pa.count)))
        }
    }
}
