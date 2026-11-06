import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Paused and playing preview frame times and the export time of a real project, with a hash of
/// every frame so two builds can be compared. REGRAVA_BENCH_PASSCACHE=<project bundle>; hashes go
/// to REGRAVA_BENCH_HASHES (a file path) when set.
struct PassCacheBenchmark {
    private static let bundlePath = ProcessInfo.processInfo.environment["REGRAVA_BENCH_PASSCACHE"]

    private static func hash(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer) * 4
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        // FNV-1a, the same in every run.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            for byte in UnsafeBufferPointer(start: base + row * rowBytes, count: width) { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        return Int(bitPattern: UInt(hash))
    }

    private static func outputBuffer(_ size: CGSize) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        return out!
    }

    /// Decoded frames of `url` from `startMs`, `count` of them, in the compositor's source format.
    private static func frames(_ url: URL, startMs: Double, count: Int) async throws -> [(ms: Double, buffer: CVPixelBuffer)] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: CanvasCompositor.sourceFormat, kCVPixelBufferMetalCompatibilityKey as String: true])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startMs / 1000, preferredTimescale: 600), duration: .positiveInfinity)
        reader.startReading()
        var frames: [(Double, CVPixelBuffer)] = []
        while frames.count < count, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000, buffer))
        }
        return frames
    }

    /// The project copied to a temporary folder, so its caches start empty and stay out of it.
    private static func copiedBundle() throws -> (dir: URL, bundle: URL, project: Project) {
        let original = URL(fileURLWithPath: bundlePath!)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("passcache-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = dir.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: bundle)
        return (dir, bundle, try ProjectStore.load(from: bundle))
    }

    private static func writeHashes(_ hashes: [String], suffix: String) throws {
        guard let path = ProcessInfo.processInfo.environment["REGRAVA_BENCH_HASHES"] else { return }
        try hashes.joined(separator: "\n").write(toFile: path + suffix, atomically: true, encoding: .utf8)
    }

    /// The buffer's rows, packed, written to `path`.
    private static func dump(_ buffer: CVPixelBuffer, to path: String) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer) * 4
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var data = Data()
        for row in 0..<CVPixelBufferGetHeight(buffer) { data.append(base + row * rowBytes, count: width) }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// A new buffer with `buffer`'s pixels: the same frame decoded again.
    private static func copy(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetPixelFormatType(buffer),
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &copy)
        CVBufferPropagateAttachments(buffer, copy!)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy!, [])
        for plane in 0..<max(1, CVPixelBufferGetPlaneCount(buffer)) {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let from = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), to = CVPixelBufferGetBytesPerRowOfPlane(copy!, plane)
            let src = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, dst = CVPixelBufferGetBaseAddressOfPlane(copy!, plane)!
            for row in 0..<rows { memcpy(dst + row * to, src + row * from, min(from, to)) }
        }
        CVPixelBufferUnlockBaseAddress(copy!, [])
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        return copy!
    }

    @Test(.enabled(if: bundlePath != nil))
    func preview() async throws {
        let (dir, bundle, project) = try Self.copiedBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let cameraURL = project.recording.cameraFileName.map { bundle.appendingPathComponent($0) }
        var hashes: [String] = []

        let height = min(project.canvasSize.height, 1080)
        let size = CGSize(width: (height * project.canvasSize.aspectRatio / 2).rounded() * 2, height: height)
        let state = RenderState(project: project, cursors: CursorLibrary.arrowOnly(), assetsDirectory: bundle, outputSize: Size2(width: size.width, height: size.height))
        let startMs = min(4000, project.recording.durationMs / 3)
        let screen = try await Self.frames(video, startMs: startMs, count: 120)
        var camera: [(ms: Double, buffer: CVPixelBuffer)] = []
        if let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) { camera = try await Self.frames(cameraURL, startMs: startMs, count: 120) }
        let out = Self.outputBuffer(size)

        func draw(_ i: Int, timeMs: Double, redecoded: Bool = false) -> Double {
            let source = redecoded ? Self.copy(screen[i].buffer) : screen[i].buffer
            let start = CFAbsoluteTimeGetCurrent()
            let cameraFrame = camera.isEmpty ? nil : camera[min(i, camera.count - 1)]
            let image = state.render(source: CIImage(cvPixelBuffer: source), camera: cameraFrame.map { CIImage(cvPixelBuffer: $0.buffer) }, cameraTimeMs: cameraFrame?.ms, timeMs: timeMs, size: size)
            CanvasCompositor.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CanvasCompositor.sRGB)
            CVPixelBufferLockBaseAddress(out, .readOnly)
            CVPixelBufferUnlockBaseAddress(out, .readOnly)
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        func report(_ name: String, _ times: [Double]) {
            let tail = times.dropFirst(5)
            let sorted = tail.sorted()
            print(String(format: "BENCH %@: avg %.2f ms, median %.2f ms, worst %.2f ms (%d frames)", name, tail.reduce(0, +) / Double(tail.count), sorted[sorted.count / 2], sorted.last ?? 0, tail.count))
        }

        // Playing: every frame new, as the player shows them.
        state.quality = .playing
        var playing: [Double] = []
        for round in 0..<2 {
            for i in screen.indices {
                playing.append(draw(i, timeMs: screen[i].ms))
                if round == 1, i % 10 == 0 { hashes.append("playing \(i) \(Self.hash(out))") }
            }
        }
        report("playing", Array(playing.dropFirst(screen.count)))

        // Paused: the same frame drawn again (a seek to the shown time, a look change undone).
        state.quality = .pausedHigh
        for (name, index) in [("paused still", 0), ("paused moving", screen.count / 2)] {
            var paused: [Double] = []
            for _ in 0..<40 { paused.append(draw(index, timeMs: screen[index].ms)) }
            hashes.append("\(name) \(Self.hash(out))")
            if let dump = ProcessInfo.processInfo.environment["REGRAVA_BENCH_DUMP"] { Self.dump(out, to: dump + "-" + name.replacingOccurrences(of: " ", with: "-") + ".raw") }
            report(name, paused)
            paused = []
            for _ in 0..<40 { paused.append(draw(index, timeMs: screen[index].ms, redecoded: true)) }
            hashes.append("\(name) redecoded \(Self.hash(out))")
            report(name + " redecoded", paused)
        }

        // Export quality, drawn as the export draws its frames.
        let settings = ExportSettings.defaults(for: .mp4)
        let exportState = ProjectExporter.renderState(project: project, cursors: CursorLibrary.arrowOnly(), bundle: bundle, settings: settings)
        let exportSize = settings.outputSize(aspectRatio: project.stageAspectRatio)
        let exportOut = Self.outputBuffer(CGSize(width: exportSize.width, height: exportSize.height))
        var exportTimes: [Double] = []
        for i in stride(from: 0, to: screen.count, by: 4) {
            let start = CFAbsoluteTimeGetCurrent()
            let cameraFrame = camera.isEmpty ? nil : camera[min(i, camera.count - 1)]
            let image = exportState.render(source: CIImage(cvPixelBuffer: screen[i].buffer), camera: cameraFrame.map { CIImage(cvPixelBuffer: $0.buffer) }, cameraTimeMs: cameraFrame?.ms,
                                           timeMs: screen[i].ms, size: CGSize(width: exportSize.width, height: exportSize.height))
            CanvasCompositor.context.render(image, to: exportOut, bounds: CGRect(x: 0, y: 0, width: exportSize.width, height: exportSize.height), colorSpace: CanvasCompositor.sRGB)
            hashes.append("export-quality \(i) \(Self.hash(exportOut))")
            exportTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        report("export-quality frame", exportTimes)
        try Self.writeHashes(hashes, suffix: ".preview")
    }

    /// Every layer at once (cursor and screen trails, clicks, captions, shortcuts, a mask, the
    /// sharpened camera with its shadow, the loupe) through a camera transition, at every quality.
    @Test(.enabled(if: bundlePath != nil))
    func everyLayer() throws {
        // The overlay camera: the person matte's network is not exact from run to run.
        var project = try JSONDecoder().decode(Project.self, from: Data(TrailInputsTests.projectJSON.utf8))
        project.cursor.clickEffect = ClickEffect(type: .ripple)
        project.captions.enableShortcuts = true
        project.keystrokes = [
            Keystroke(kind: .down, timeMs: 1300, character: "k", activeModifiers: [.command, .shift]),
            Keystroke(kind: .up, timeMs: 1400, character: "k", activeModifiers: [.command, .shift]),
        ]
        project.camera.sharpen01 = 0.5
        project.processing.improveRecordingQuality01 = 1
        let track = CameraTrack(project: project, fps: 60)
        let size = CGSize(width: 1920, height: 1080)
        let compositor = FrameCompositor(project: project, layout: track.layout, cursors: CursorLibrary.arrowOnly(), transcript: PassInputsTests.words, fps: 60, outputScale: size.width / track.layout.canvas.width)
        let source = CIImage(cvPixelBuffer: PassInputsTests.buffer(3024, 1964, seed: 0))
        let camera = CIImage(cvPixelBuffer: PassInputsTests.buffer(1920, 1080, seed: 50))
        let out = Self.outputBuffer(size)
        var hashes: [String] = []
        for quality in [RenderQuality.export, .pausedHigh, .playing] {
            var times: [Double] = []
            for t in stride(from: 800.0, to: 2600, by: 50) {
                var frame = track.frame(at: t)
                frame.loupe = LoupeFrame(center: Vec2(0.4, 0.5), radius: 0.15, zoom: 2, bevelRatio: 0.2, chromaticAberration: 0.5, shadowAlpha: 0.3, presence: 1)
                frame.clicks = [CursorClick(ageMs: 200, position: Vec2(1500, 1000))]
                frame.mask = MaskFrame(bounds01: Rect2(x: 0.1, y: 0.2, width: 0.3, height: 0.2), borderRadius01: 0.01, type: .sensitiveData, highlightOpacity: 0.5, active: true, opacity: 1)
                for _ in 0..<3 {
                    let start = CFAbsoluteTimeGetCurrent()
                    let image = compositor.compose(source: source, camera: camera, frame: frame, quality: quality).cropped(to: CGRect(origin: .zero, size: size))
                    CanvasCompositor.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CanvasCompositor.sRGB)
                    CVPixelBufferLockBaseAddress(out, .readOnly)
                    CVPixelBufferUnlockBaseAddress(out, .readOnly)
                    times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
                hashes.append("every-layer \(quality) \(Int(t)) \(Self.hash(out))")
            }
            let sorted = times.sorted()
            print(String(format: "BENCH every layer %@ (each frame 3×): avg %.2f ms, median %.2f ms", "\(quality)", times.reduce(0, +) / Double(times.count), sorted[sorted.count / 2]))
        }
        try Self.writeHashes(hashes, suffix: ".every")
    }

    @Test(.enabled(if: bundlePath != nil))
    func export() async throws {
        let (dir, bundle, project) = try Self.copiedBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = ProjectStore.videoURL(bundle: bundle, project: project)
        let exportURL = dir.appendingPathComponent("export.mp4")
        let exportStart = Date()
        try await ProjectExporter.export(project: project, videoURL: video, settings: ExportSettings.defaults(for: .mp4), to: exportURL, cursors: CursorLibrary.arrowOnly()) { p in
            if Int(p * 100) % 10 == 0 { FileHandle.standardError.write("export \(Int(p * 100))%\n".data(using: .utf8)!) }
        }
        print(String(format: "BENCH export: %.2f s for %.1f s of video", Date().timeIntervalSince(exportStart), project.recording.durationMs / 1000))
    }
}
