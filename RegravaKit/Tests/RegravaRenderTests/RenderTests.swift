import AVFoundation
import CoreImage
import Foundation
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
            style: StyleConfig(canvas: Size2(width: 1280, height: 720))
        )
        project.zooms = [ZoomRange(startMs: 200, endMs: 1500, scale: 2)]
        return project
    }

    @Test func composesFrameAtCanvasSize() {
        let project = sampleProject(duration: 2000)
        let snapshot = RenderState.makeSnapshot(project: project, cursor: nil)
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = snapshot.compositor.compose(source: source, frame: snapshot.track.frame(at: 1000))
        #expect(image.extent == CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    /// Set REGRAVA_SNAPSHOT_DIR to write rest/zoomed PNG frames for visual inspection.
    @Test func writesSnapshotsWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] else { return }
        let project = sampleProject(duration: 2000)
        let snapshot = RenderState.makeSnapshot(project: project, cursor: CursorAsset.defaultArrow())
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 40, "inputColor0": CIColor.white, "inputColor1": CIColor(red: 0.2, green: 0.4, blue: 0.8),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let context = CIContext()
        for t in [0.0, 1400.0] {
            let image = snapshot.compositor.compose(source: checker, frame: snapshot.track.frame(at: t))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("frame-\(Int(t)).png")
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }

    @Test func exportsComposedVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regrava-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("recording.mov")
        let output = dir.appendingPathComponent("export.mp4")
        try await makeTestVideo(url: source, width: 640, height: 360, frames: 60, fps: 30)

        try await VideoExporter.export(project: sampleProject(duration: 2000), videoURL: source, to: output, cursor: nil)

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 1280, height: 720))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.2)
    }
}
