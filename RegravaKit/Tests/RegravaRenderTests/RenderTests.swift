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

    @Test func drawsTheWebcamInItsLayoutRect() {
        var project = sampleProject(duration: 2000)
        project.zooms = []
        project.style.shadow.intensity = 0
        project.recording.cameraFileName = "camera.mov"
        project.recording.cameraSize = Size2(width: 320, height: 180)
        let snapshot = RenderState.makeSnapshot(project: project, cursors: nil)
        let frame = snapshot.track.frame(at: 1000)
        let rect = frame.cameraRect!
        let screen = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let camera = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let image = snapshot.compositor.compose(source: screen, camera: camera, frame: frame)
        var pixel = [UInt8](repeating: 0, count: 4)
        // Centre of the camera, in Core Image (bottom-left) coordinates.
        let point = CGRect(x: rect.midX, y: 1080 - rect.midY, width: 1, height: 1)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 4, bounds: point, format: .RGBA8, colorSpace: nil)
        #expect(pixel[0] > 240 && pixel[2] < 15)
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

    @Test func exportFollowsClipSpeedAndCuts() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("clips.mp4")
            var project = sampleProject(duration: 2000)
            project.splitSlice(at: 1000)
            project.slices[1].timeScale = 0.5                          // 1–2 s at 2× → 0.5 s
            project.updateSlice(project.slices[0].id, sourceEndMs: 600) // cut 0.6–1 s
            #expect(abs(project.playbackDurationMs - 1100) < 1)
            try await ProjectExporter.export(project: project, videoURL: source, settings: .defaults(for: .mp4), to: output, cursors: nil)
            let info = try await videoInfo(output)
            #expect(abs(info.duration - 1.1) < 0.15)
        }
    }

    @Test func gifExportFollowsClips() async throws {
        try await withTestVideo { source, dir in
            let output = dir.appendingPathComponent("clips.gif")
            var project = sampleProject(duration: 2000)
            project.splitSlice(at: 1000)
            project.slices[1].timeScale = 0.5
            var settings = ExportSettings.defaults(for: .gif)
            settings.fps = 10
            try await ProjectExporter.export(project: project, videoURL: source, settings: settings, to: output, cursors: nil)
            let gif = CGImageSourceCreateWithURL(output as CFURL, nil)
            // 1.5 s of playback at 10 fps.
            #expect(abs(Double(gif.map(CGImageSourceGetCount) ?? 0) - 15) <= 2)
        }
    }

    @Test func webcamBecomesTheSecondVideoTrack() async throws {
        try await withTestVideo { source, dir in
            let assets = ProjectStore.assetsURL(bundle: dir)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try await makeTestVideo(url: dir.appendingPathComponent("camera.mov"), width: 320, height: 180, frames: 45, fps: 30)
            var project = sampleProject(duration: 2000)
            project.recording.cameraFileName = "camera.mov"
            project.recording.cameraSize = Size2(width: 320, height: 180)
            let media = try await PlaybackComposition.media(asset: AVURLAsset(url: source), project: project, assetsDirectory: assets)
            let tracks = try await media.asset.loadTracks(withMediaType: .video)
            #expect(tracks.count == 2)
            let output = dir.appendingPathComponent("camera-export.mp4")
            try await ProjectExporter.export(project: project, videoURL: source, settings: ExportSettings.defaults(for: .mp4), to: output, cursors: nil)
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func sharpenRaisesEdgeContrast() {
        let left = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let right = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7)).cropped(to: CGRect(x: 8, y: 0, width: 8, height: 8))
        let image = right.composited(over: left)
        let sharp = FrameCompositor.sharpened(image, amount: 1)
        #expect(sharp.extent == image.extent)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixels = [UInt8](repeating: 0, count: 16 * 4)
        context.render(sharp, toBitmap: &pixels, rowBytes: 16 * 4, bounds: CGRect(x: 0, y: 4, width: 16, height: 1), format: .RGBA8, colorSpace: nil)
        // The dark side of the edge gets darker, the bright side brighter; flat areas stay.
        #expect(pixels[7 * 4] < 70)
        #expect(pixels[8 * 4] > 185)
        #expect(abs(Int(pixels[2 * 4]) - 77) <= 1)
        #expect(FrameCompositor.sharpened(image, amount: 0) === image)
    }

    @Test func backgroundAudioRepeatsUntilTheEnd() async throws {
        try await withTestVideo { source, dir in
            // 0.5 s tone as background audio in the project's assets folder.
            let assets = ProjectStore.assetsURL(bundle: dir)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try AVAudioFile(forWriting: assets.appendingPathComponent("music.caf"), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
            buffer.frameLength = 22_050
            for i in 0..<22_050 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.5 }
            try file.write(from: buffer)

            var project = sampleProject(duration: 2000)
            project.audio.backgroundAudioFileName = "music.caf"
            let media = try await PlaybackComposition.media(asset: AVURLAsset(url: source), project: project, assetsDirectory: assets)
            let tracks = try await media.asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 1)
            let range = try await tracks[0].load(.timeRange)
            #expect(abs(range.duration.seconds - 2) < 0.05)
            var volume: Float = 0
            let parameters = try #require(media.audioMix?.inputParameters.first)
            _ = parameters.getVolumeRamp(for: .zero, startVolume: &volume, endVolume: nil, timeRange: nil)
            #expect(abs(volume - 0.05) < 0.001)

            project.audio.muteBackgroundAudio = true
            let muted = try await PlaybackComposition.media(asset: AVURLAsset(url: source), project: project, assetsDirectory: assets)
            #expect(try await muted.asset.loadTracks(withMediaType: .audio).isEmpty)
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
