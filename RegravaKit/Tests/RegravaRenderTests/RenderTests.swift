import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Writes a short solid-color H.264 movie to disk.
private func makeTestVideo(url: URL, width: Int, height: Int, frames: Int, fps: Int32) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let context = CIContext()
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let shade = CGFloat(i) / CGFloat(frames)
        let image = CIImage(color: CIColor(red: shade, green: 0.3, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(image, to: buffer!)
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Suite struct RenderTests {
    func sampleProject(duration: Double) -> Project {
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 640, height: 360), pointPixelScale: 1, durationMs: duration, fps: 30),
            mouseEvents: [
                MouseEvent(kind: .move, timeMs: 0, position: Vec2(100, 100)),
                MouseEvent(kind: .down, timeMs: 400, position: Vec2(500, 300)),
                MouseEvent(kind: .up, timeMs: 450, position: Vec2(500, 300)),
            ],
            style: StyleConfig(aspectRatio: 16.0 / 9)
        )
        project.zooms = [ZoomRange(startMs: 200, endMs: 1500, scale: 2)]
        return project
    }

    @Test func composesFrameAtCanvasSize() {
        let project = sampleProject(duration: 2000)
        let snapshot = RenderState.makeSnapshot(project: project, cursors: nil)
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = snapshot.compositor.compose(source: source, frame: snapshot.track.frame(at: 1000))
        #expect(image.extent == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    /// Set REGRAVA_SNAPSHOT_DIR to write rest/zoomed PNG frames for visual inspection.
    @Test func writesSnapshotsWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] else { return }
        var project = sampleProject(duration: 2000)
        project.style.inset = .enabledDefault
        project.cursor.clickEffect = .ripple
        let snapshot = RenderState.makeSnapshot(project: project, cursors: CursorLibrary.arrowOnly())
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 40, "inputColor0": CIColor.white, "inputColor1": CIColor(red: 0.2, green: 0.4, blue: 0.8),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let context = CIContext()
        for t in [0.0, 500.0, 1400.0] {
            let image = snapshot.compositor.compose(source: checker, frame: snapshot.track.frame(at: t))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("frame-\(Int(t)).png")
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // Click effects in the middle of a resting screen.
        for effect in ClickEffect.allCases {
            project.cursor.clickEffect = effect
            let effectSnapshot = RenderState.makeSnapshot(project: project, cursors: nil)
            var frame = effectSnapshot.track.frame(at: 0)
            frame.screenRect = effectSnapshot.track.layout.restScreen
            frame.clickProgress = 0.3
            frame.clickPosition = Vec2(320, 180)
            let image = effectSnapshot.compositor.compose(source: checker, frame: frame)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("click-\(effect.rawValue).png")
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }

    private func withTestVideo(_ body: (URL, URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regrava-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("recording.mov")
        try await makeTestVideo(url: source, width: 640, height: 360, frames: 60, fps: 30)
        try await body(source, dir)
    }

    private func videoInfo(_ url: URL) async throws -> (size: CGSize, duration: Double, fps: Float, codec: FourCharCode) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        return (
            try await track.load(.naturalSize),
            try await asset.load(.duration).seconds,
            try await track.load(.nominalFrameRate),
            CMFormatDescriptionGetMediaSubType(format)
        )
    }

    @Test func exportsMP4WithChosenResolutionAndFrameRate() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("export.mp4")
            var settings = ExportSettings.defaults(for: .mp4)
            settings.fps = 10
            try await ProjectExporter.export(project: sampleProject(duration: 2000), videoURL: source, settings: settings, to: output, cursors: nil)
            let info = try await videoInfo(output)
            #expect(info.size == CGSize(width: 1280, height: 720))
            #expect(abs(info.duration - 2) < 0.2)
            #expect(abs(info.fps - 10) < 1)
            #expect(info.codec == kCMVideoCodecType_H264)
        }
    }

    @Test func exportsBothCodecsAsTwoFiles() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("export.mp4")
            var settings = ExportSettings.defaults(for: .mp4)
            settings.codec = .both
            let files = try await ProjectExporter.export(project: sampleProject(duration: 2000), videoURL: source, settings: settings, target: .file, to: output, cursors: nil)
            #expect(files.count == 2)
            #expect(try await videoInfo(files[0]).codec == kCMVideoCodecType_H264)
            #expect(try await videoInfo(files[1]).codec == kCMVideoCodecType_HEVC)
        }
    }

    @Test func exportsProRes() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("export.mov")
            var settings = ExportSettings.defaults(for: .prores)
            settings.height = 720
            try await ProjectExporter.export(project: sampleProject(duration: 2000), videoURL: source, settings: settings, to: output, cursors: nil)
            #expect(try await videoInfo(output).codec == kCMVideoCodecType_AppleProRes422HQ)
        }
    }

    @Test func frameRateLimiterKeepsEveryOtherFrame() {
        let times = (0..<60).map { Double($0) / 30 }
        let kept = FrameRateLimiter.select(times: times, fps: 15, duration: 2)
        #expect(kept.count == 30)
        #expect(FrameRateLimiter.select(times: times, fps: 60, duration: 2).count == 60)
    }

    @Test func exportsGIF() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("export.gif")
            try await ProjectExporter.export(project: sampleProject(duration: 2000), videoURL: source, settings: .defaults(for: .gif), to: output, cursors: nil)
            let gif = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            var totalDelay = 0.0
            for i in 0..<CGImageSourceGetCount(gif) {
                let props = CGImageSourceCopyPropertiesAtIndex(gif, i, nil) as? [CFString: Any]
                let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                totalDelay += (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
            }
            #expect(abs(totalDelay - 2) < 0.15)
            let first = try #require(CGImageSourceCreateImageAtIndex(gif, 0, nil))
            #expect(first.height == 480)
        }
    }

    @Test func cancellationStopsExportAndRemovesFile() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("export.mp4")
            let task = Task {
                try await ProjectExporter.export(project: sampleProject(duration: 2000), videoURL: source, settings: .defaults(for: .mp4), to: output, cursors: nil)
            }
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}
