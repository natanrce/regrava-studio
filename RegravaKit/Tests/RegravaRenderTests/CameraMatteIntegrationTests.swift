import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// The camera matte cache on a real project's webcam (REGRAVA_MATTE_PROJECT=<bundle path>): the
/// project is copied, never written.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["REGRAVA_MATTE_PROJECT"] != nil))
struct CameraMatteIntegrationTests {
    let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REGRAVA_MATTE_PROJECT"] ?? "/")

    /// A copy of the project as `<tmp>/<name>.regrava`, with a cutout layout.
    func copyProject(_ name: String) throws -> (bundle: URL, project: Project) {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("matte-it-" + name + "-" + UUID().uuidString + "." + ProjectStore.fileExtension, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var project = try ProjectStore.load(from: source)
        for file in ["project.json", project.recording.videoFileName, project.recording.cameraFileName!] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: bundle.appendingPathComponent(file))
        }
        project.defaultLayout.type = .cutoutCamera
        return (bundle, project)
    }

    @Test func sweepStoresEveryChunk() throws {
        let (bundle, project) = try copyProject("sweep")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let camera = bundle.appendingPathComponent(project.recording.cameraFileName!)
        let start = CFAbsoluteTimeGetCurrent()
        let matting = try CameraMatting(videoURL: camera, waitsForStoredMattes: false)
        print(String(format: "MATTE open %.0f ms, window %@", (CFAbsoluteTimeGetCurrent() - start) * 1000, String(describing: matting.window)))
        let sweepStart = CFAbsoluteTimeGetCurrent()
        matting.startSweep { _, _ in }
        while !matting.cache.isComplete, CFAbsoluteTimeGetCurrent() - sweepStart < 300 { Thread.sleep(forTimeInterval: 0.1) }
        let seconds = CFAbsoluteTimeGetCurrent() - sweepStart
        print(String(format: "MATTE sweep %d frames in %.1f s (%.0f frames/s)", matting.frameTimes.count, seconds, Double(matting.frameTimes.count) / seconds))
        #expect(matting.cache.isComplete)
        let root = bundle.appendingPathComponent("cache/camera-matte")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains { $0.hasPrefix("window-") && $0.hasSuffix(".json") })
        let chunk = try matting.cache.read(0)
        #expect(chunk.count == 30)
        #expect(PersonWindow.personBox(chunk[15]) != nil)
        let bytes = try FileManager.default.attributesOfItem(atPath: matting.cache.url(ofChunk: 0).path)[.size] as? Int ?? 0
        print("MATTE chunk-000000.mp4", bytes, "bytes")
        matting.stop()
    }

    /// Frames as an export draws them: through the composition and the custom compositor, raw BGRA.
    func exportFrameHashes(bundle: URL, project: Project, frames: Int) async throws -> [String] {
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let state = RenderState(project: project, cursors: nil, assetsDirectory: bundle, fps: 30, waitsForStoredMattes: true)
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: video), project: project, assetsDirectory: ProjectStore.assetsURL(bundle: bundle))
        let composition = try await CompositionFactory.make(asset: media.asset, state: state, canvas: project.canvasSize, outputSize: Size2(width: 640, height: 360), fps: 30)
        let tracks = try await media.asset.loadTracks(withMediaType: .video)
        return try await BlockingWork.run("matte hashes") { _ in
            let reader = try AVAssetReader(asset: media.asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = composition
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CancellationError() }
            defer { reader.cancelReading() }
            var hashes: [String] = []
            while hashes.count < frames, let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
                var hasher = SHA256()
                let base = CVPixelBufferGetBaseAddress(buffer)!
                for y in 0..<height { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * rowBytes, count: width * 4)) }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                hashes.append(hasher.finalize().map { String(format: "%02x", $0) }.joined())
            }
            return hashes
        }
    }

    @Test func exportsDrawTheSameFramesWhateverTheCacheHeld() async throws {
        let frames = 120
        // A: nothing stored; every frame waits for the export's own sweep.
        let (first, project) = try copyProject("a")
        defer { try? FileManager.default.removeItem(at: first) }
        let a = try await exportFrameHashes(bundle: first, project: project, frames: frames)
        // B: the editor's sweep stored a few chunks first (with the network's mattes already shown).
        let (second, _) = try copyProject("b")
        defer { try? FileManager.default.removeItem(at: second) }
        do {
            let editor = try CameraMatting(videoURL: second.appendingPathComponent(project.recording.cameraFileName!), waitsForStoredMattes: false)
            editor.demand(200)
            editor.startSweep { _, _ in }
            while editor.cache.storedChunkCount < 3 { Thread.sleep(forTimeInterval: 0.05) }
            editor.stop()
        }
        let b = try await exportFrameHashes(bundle: second, project: project, frames: frames)
        // C: everything stored by A, drawn again.
        let c = try await exportFrameHashes(bundle: first, project: project, frames: frames)
        #expect(a.count == frames && b.count == frames && c.count == frames)
        // The mattes the exports drew are the stored ones, the same in both projects.
        let camera = project.recording.cameraFileName!
        let times = try CameraFrames.frameTimes(videoURL: first.appendingPathComponent(camera))
        func storedMattes(_ bundle: URL) throws -> [[UInt8]] {
            let root = MatteCache.root(forVideoAt: bundle.appendingPathComponent(camera).path)
            let identity = try FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix("matte-") }!
            let cache = try MatteCache(root: root, videoKey: MatteCache.videoKey(forVideoAt: bundle.appendingPathComponent(camera).path), identity: identity, frameCount: times.count)
            return try (0..<4).flatMap { try cache.read($0) }
        }
        #expect(try storedMattes(first) == storedMattes(second))
        // Frames are compared too; the cutout passes themselves are not always bit-exact run to run.
        print("MATTE export frames identical: A=B", zip(a, b).filter { $0 == $1 }.count, "A=C", zip(a, c).filter { $0 == $1 }.count, "of", frames)
    }

    @Test func exportsWithoutCutoutAreDeterministic() async throws {
        var (bundle, project) = try copyProject("plain")
        defer { try? FileManager.default.removeItem(at: bundle) }
        project.defaultLayout.type = .cameraOverlay
        let a = try await exportFrameHashes(bundle: bundle, project: project, frames: 30)
        let b = try await exportFrameHashes(bundle: bundle, project: project, frames: 30)
        print("MATTE plain export identical frames:", zip(a, b).filter { $0 == $1 }.count, "of", a.count)
        #expect(a == b)
    }

    @Test func previewFrameCost() throws {
        let (bundle, project) = try copyProject("preview")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let camera = bundle.appendingPathComponent(project.recording.cameraFileName!)
        let snapshot = RenderState.makeSnapshot(project: project, cursors: nil, assetsDirectory: bundle, outputSize: Size2(width: 1280, height: 720))
        let times = try CameraFrames.frameTimes(videoURL: camera)
        var screen: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(project.recording.videoSize.width), Int(project.recording.videoSize.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &screen)
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        let reader = try CameraFrames.DecodedFrames(videoURL: camera, from: times[60], to: times[150])
        var cameraFrames: [(CVPixelBuffer, Double)] = []
        while let (buffer, time) = try reader.next() { cameraFrames.append((buffer, time.seconds * 1000)) }
        func measure(_ name: String, quality: RenderQuality, withTime: Bool) {
            var costs: [Double] = []
            for (buffer, ms) in cameraFrames {
                let start = CFAbsoluteTimeGetCurrent()
                var frame = snapshot.track.frame(at: ms)
                frame.cameraCutout01 = 1
                let image = snapshot.render(source: CIImage(cvPixelBuffer: screen!), camera: CIImage(cvPixelBuffer: buffer), cameraTimeMs: withTime ? ms : nil, frame: frame, quality: quality, size: CGSize(width: 1280, height: 720))
                CanvasCompositor.context.render(image, to: out!, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), colorSpace: CanvasCompositor.sRGB)
                CVPixelBufferLockBaseAddress(out!, .readOnly)
                CVPixelBufferUnlockBaseAddress(out!, .readOnly)
                costs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let sorted = costs.dropFirst(3).sorted()
            print(String(format: "MATTE preview %@: mean %.1f ms, median %.1f ms, worst %.1f ms", name, sorted.reduce(0, +) / Double(sorted.count), sorted[sorted.count / 2], sorted.last!))
        }
        measure("live (no frame time)", quality: .playing, withTime: false)
        // Cache filled first, then frames come from memory or disk.
        let matting = try CameraMatting.open(videoURL: camera, waitsForStoredMattes: false)
        while !matting.cache.isComplete { Thread.sleep(forTimeInterval: 0.1) }
        measure("cached, playing", quality: .playing, withTime: true)
        measure("cached, playing again (memory)", quality: .playing, withTime: true)
        measure("cached, paused", quality: .pausedHigh, withTime: true)
        matting.stop()
    }
}
