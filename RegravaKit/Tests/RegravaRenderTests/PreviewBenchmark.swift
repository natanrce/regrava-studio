import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Per-frame render cost of moving frames; runs only with REGRAVA_BENCH=1.
struct PreviewBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_BENCH"] == "1"))
    func frameCost() throws {
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 3024, height: 1964), pointPixelScale: 2, durationMs: 4000, fps: 60),
            mouseEvents: [
                MouseEvent(kind: .move, timeMs: 0, position: Vec2(200, 200)),
                MouseEvent(kind: .move, timeMs: 1500, position: Vec2(2600, 1600)),
                MouseEvent(kind: .down, timeMs: 1600, position: Vec2(2600, 1600)),
                MouseEvent(kind: .up, timeMs: 1650, position: Vec2(2600, 1600)),
            ],
            style: StyleConfig(aspectRatio: 16.0 / 9)
        )
        project.zooms = [ZoomRange(startMs: 300, endMs: 3000, scale: 2.5)]
        let snapshot = RenderState.makeSnapshot(project: project, cursors: CursorLibrary.arrowOnly())
        let context = CIContext(options: [.cacheIntermediates: false])
        var sourceBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 3024, 1964, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &sourceBuffer)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 3024, height: 1964))
        context.render(noise, to: sourceBuffer!)
        let source = CIImage(cvPixelBuffer: sourceBuffer!)

        func measure(_ name: String, quality: RenderQuality, output: CGSize) {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(output.width), Int(output.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
            let times = stride(from: 300.0, to: 1500, by: 1000.0 / 60)
            var total = 0.0, worst = 0.0
            for (i, t) in times.enumerated() {
                let start = CFAbsoluteTimeGetCurrent()
                var image = snapshot.compositor.compose(source: source, frame: snapshot.track.frame(at: t), quality: quality)
                let s = output.width / 1920
                if s != 1 { image = image.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
                context.render(image.cropped(to: CGRect(origin: .zero, size: output)), to: out!, bounds: CGRect(origin: .zero, size: output), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                CVPixelBufferLockBaseAddress(out!, .readOnly)
                CVPixelBufferUnlockBaseAddress(out!, .readOnly)
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                if i > 2 { total += ms; worst = max(worst, ms) }
            }
            let n = Double(times.underestimatedCount - 3)
            print(String(format: "BENCH %@: avg %.1f ms, worst %.1f ms", name, total / n, worst))
        }
        measure("canvas 1920 export-quality (cold)", quality: .export, output: CGSize(width: 1920, height: 1080))
        measure("canvas 1920 export-quality (warm)", quality: .export, output: CGSize(width: 1920, height: 1080))
        measure("canvas 1920 playing (cold)", quality: .playing, output: CGSize(width: 1920, height: 1080))
        measure("canvas 1920 playing (warm)", quality: .playing, output: CGSize(width: 1920, height: 1080))
        measure("preview 960 export-quality", quality: .export, output: CGSize(width: 960, height: 540))
        measure("preview 960 playing", quality: .playing, output: CGSize(width: 960, height: 540))
    }
}

import AVFoundation

/// Decode + compose throughput on a real project (REGRAVA_BENCH_PROJECT=<bundle path>).
struct PipelineBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_BENCH_PROJECT"] != nil))
    func pipelineThroughput() async throws {
        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REGRAVA_BENCH_PROJECT"]!)
        let project = try ProjectStore.load(from: bundle)
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: video), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundle))
        let track = try await AVURLAsset(url: video).loadTracks(withMediaType: .video)[0]
        print("BENCH source", try await track.load(.naturalSize), "fps", try await track.load(.nominalFrameRate), "canvas", project.canvasSize)
        let prewarm = ProcessInfo.processInfo.environment["REGRAVA_BENCH_PREWARM"] == "1"
        for quality in [RenderQuality.playing, .playing] {
            let state = RenderState(project: project, cursors: CursorLibrary.arrowOnly(), assetsDirectory: bundle)
            state.quality = quality
            let height = min(project.canvasSize.height, 1080)
            let output = Size2(width: (height * project.canvasSize.aspectRatio / 2).rounded() * 2, height: height)
            if prewarm {
                let t0 = CFAbsoluteTimeGetCurrent()
                CompositionFactory.prewarm(state: state, outputSize: output)
                print(String(format: "BENCH prewarm %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            }
            let configuration = try await CompositionFactory.configuration(asset: media.asset, state: state, canvas: project.canvasSize, outputSize: output, fps: 60)
            let reader = try AVAssetReader(asset: media.asset)
            let tracks = try await media.asset.loadTracks(withMediaType: .video)
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: nil)
            out.videoComposition = AVVideoComposition(configuration: configuration)
            reader.add(out)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(project.recording.durationMs / 1000, 15), preferredTimescale: 600))
            reader.startReading()
            var count = 0, worst = 0.0
            let start = CFAbsoluteTimeGetCurrent()
            var last = start
            var slow: [String] = []
            while let sample = out.copyNextSampleBuffer() {
                let now = CFAbsoluteTimeGetCurrent()
                if count > 5 { worst = max(worst, (now - last) * 1000) }
                if count > 5 && (now - last) * 1000 > 16.7 { slow.append(String(format: "%.0fms@%.2fs", (now - last) * 1000, CMSampleBufferGetPresentationTimeStamp(sample).seconds)) }
                last = now
                count += 1
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            print("BENCH slow frames:", slow.prefix(30).joined(separator: " "))
            print(String(format: "BENCH pipeline %@: %d frames, %.1f fps, avg %.1f ms, worst gap %.1f ms", "\(quality)", count, Double(count) / elapsed, elapsed * 1000 / Double(count), worst))
        }
    }
}

struct DecodeBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_BENCH_PROJECT"] != nil))
    func decodeGaps() async throws {
        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REGRAVA_BENCH_PROJECT"]!)
        let project = try ProjectStore.load(from: bundle)
        let asset = AVURLAsset(url: ProjectStore.videoURL(bundle: bundle, project: project))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        for (name, format) in [("BGRA", kCVPixelFormatType_32BGRA), ("420v", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)] {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferMetalCompatibilityKey as String: true])
            reader.add(out)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 15, preferredTimescale: 600))
            reader.startReading()
            var gaps: [Double] = []
            var last = CFAbsoluteTimeGetCurrent()
            let start = last
            while out.copyNextSampleBuffer() != nil {
                let now = CFAbsoluteTimeGetCurrent()
                gaps.append((now - last) * 1000)
                last = now
            }
            let tail = gaps.dropFirst(5)
            print(String(format: "BENCH decode %@: %d frames in %.0f ms, worst %.1f ms, over 16 ms: %d", name, gaps.count, (last - start) * 1000, tail.max() ?? 0, tail.filter { $0 > 16.7 }.count))
        }
    }
}
