import AVFoundation
import AppKit
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func detection(_ kind: SensitiveDataKind, x: Double, startMs: Double = 0, endMs: Double = 20_000) -> SensitiveDataDetection {
    SensitiveDataDetection(kind: kind, text: "", startMs: startMs, endMs: endMs, keyframes: [.init(timeMs: startMs, x: x, y: 10, width: 40, height: 10)],
                           videoWidthPx: 640, videoHeightPx: 360)
}

private func partial(finalUpToMs: Double, detections: [SensitiveDataDetection], provisional: [SensitiveDataDetection] = []) -> SensitiveDataScanner.PartialResult {
    SensitiveDataScanner.PartialResult(detections: detections, finalUpToMs: finalUpToMs, analyzedUpToMs: finalUpToMs, provisionalDetections: provisional,
                                       provisionalFromMs: provisional.isEmpty ? 0 : 10_000, provisionalToMs: provisional.isEmpty ? 0 : 12_000)
}

private func waitFor(_ condition: () -> Bool, seconds: Double = 5) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
}

struct ExportSensitiveDataTests {
    private func scan() -> SharedSensitiveDataScan {
        SharedSensitiveDataScan(key: .init(video: "/tmp/export-sd-\(UUID().uuidString).mov", phrases: [], detectFaces: false))
    }

    private func bundle() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export-sd-\(UUID().uuidString).regrava")
    }

    /// A frame at t waits until the partial result is final past t + 1000 ms, then draws only its
    /// final detections. The export demands the frame's time while it waits.
    @Test func aFrameWaitsUntilThePartialResultIsFinalASecondPastIt() async throws {
        let scan = scan(), bundle = bundle()
        let source = ExportSensitiveData(scan: scan, bundle: bundle, requesterId: "export-a", firstSourceMs: 0)
        defer { source.stop() }
        let drawn = Box<AutoMaskTimeline>()
        let final = detection(.email, x: 10), ahead = detection(.phone, x: 300, startMs: 10_000)
        Thread { drawn.value = source.timeline(atSourceMs: 5000) }.start()
        try await waitFor { SensitiveDataScans.nextDemandMs(bundle: bundle) == 5000 }
        #expect(SensitiveDataScans.nextDemandMs(bundle: bundle) == 5000)

        scan.deliver(partial(finalUpToMs: 5999, detections: [final], provisional: [ahead]))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(drawn.value == nil)
        // 5000 + 1000 < 6000 does not hold either.
        scan.deliver(partial(finalUpToMs: 6000, detections: [final], provisional: [ahead]))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(drawn.value == nil)

        scan.deliver(partial(finalUpToMs: 6001, detections: [final], provisional: [ahead]))
        try await waitFor { drawn.value != nil }
        #expect(drawn.value?.detections == [final])
        #expect(SensitiveDataScans.nextDemandMs(bundle: bundle) == nil)
        #expect(source.usedPartialCount == 1)
        // Earlier frames are ready right away.
        #expect(source.timeline(atSourceMs: 4000).detections == [final])
    }

    /// A failed scan lets the frames through with the last partial result; a finished one draws
    /// its result and is no longer recorded as used.
    @Test func aSettledScanReleasesTheFrames() async throws {
        let scan = scan()
        let source = ExportSensitiveData(scan: scan, bundle: bundle(), requesterId: "export-b", firstSourceMs: 0)
        defer { source.stop() }
        let drawn = Box<AutoMaskTimeline>()
        Thread { drawn.value = source.timeline(atSourceMs: 9000) }.start()
        let result = [detection(.email, x: 20)]
        scan.settle(.success(result))
        try await waitFor { drawn.value != nil }
        #expect(drawn.value?.detections == result)
        #expect(source.usedPartialCount == 0)
        #expect(await source.isStale() == false)
    }

    /// The complete result is compared over each drawn range widened by a second, cut off where
    /// the partial result used was final.
    @Test func staleWhenTheCompleteResultChangesADrawnRange() async throws {
        func run(result: [SensitiveDataDetection]) async -> Bool {
            let scan = scan()
            let source = ExportSensitiveData(scan: scan, bundle: bundle(), requesterId: "export-c", firstSourceMs: 0)
            defer { source.stop() }
            scan.deliver(partial(finalUpToMs: 4000, detections: [detection(.email, x: 10, endMs: 2500)]))
            _ = source.timeline(atSourceMs: 1000)
            _ = source.timeline(atSourceMs: 2000)
            scan.settle(.success(result))
            return await source.isStale()
        }
        // The same over 0…3000 (and later, past where the partial result was final, differs).
        #expect(await run(result: [detection(.email, x: 10, endMs: 2500), detection(.phone, x: 200, startMs: 3500)]) == false)
        #expect(await run(result: [detection(.email, x: 11, endMs: 2500)]) == true)
        #expect(await run(result: [detection(.email, x: 10, endMs: 2500), detection(.phone, x: 200, startMs: 2900)]) == true)
        #expect(await run(result: [detection(.email, x: 10, endMs: 2600)]) == true)
    }

    // MARK: Export

    /// Eight seconds of a page whose text changes every two seconds.
    private func makeTextVideo(url: URL) async throws {
        let width = 640, height = 360, fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let lines = ["Contact: john.doe@example.com", "Call +1 415 555 0132 today", "Mail anna.smith@example.org", "Write to bob.jones@example.net"]
        var pages: [CVPixelBuffer] = []
        for (index, line) in lines.enumerated() {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (line as NSString).draw(at: NSPoint(x: 40 + index * 20, y: 200 - index * 30), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
            NSGraphicsContext.current = nil
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            pages.append(buffer!)
        }
        for i in 0..<80 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(pages[i / 20], withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func decodedFrames(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var frames: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer) * 4
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var frame = Data(capacity: width * CVPixelBufferGetHeight(buffer))
            for row in 0..<CVPixelBufferGetHeight(buffer) { frame.append(base + row * rowBytes, count: width) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(frame)
        }
        return frames
    }

    /// Rendering while the scan runs writes the frames an export after the complete scan writes.
    @Test func anExportAlongsideTheScanMatchesOneAfterIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-sd-\(UUID().uuidString)", isDirectory: true)
        let bundle = dir.appendingPathComponent("streaming.regrava", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = bundle.appendingPathComponent("recording.mov")
        try await makeTextVideo(url: video)

        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 640, height: 360), pointPixelScale: 1, durationMs: 8000, fps: 10),
                              mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(100, 100))], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.processing.autoMaskSensitiveData = true
        var settings = ExportSettings.defaults(for: .prores)
        settings.fps = 10
        settings.height = 360
        // Short chunks scanned one by one, final as soon as stored, so frames are drawn on the way.
        var options = SensitiveDataScanner.Options()
        options.chunkMs = 2000
        options.decodeThreads = 1
        options.partialFinalLagMs = 0

        let streamed = dir.appendingPathComponent("streamed.mov")
        let observed = Box<ExportSensitiveData>()
        try await ProjectExporter.export(project: project, videoURL: video, settings: settings, to: streamed, cursors: nil, readsAhead: true,
                                         sensitiveDataOptions: options, observeSensitiveData: { observed.value = $0 })
        let source = try #require(observed.value)
        #expect(source.usedPartialCount > 0)
        let stored = try #require(SensitiveDataScan.load(bundle: bundle))
        #expect(stored.isComplete && !stored.detections.isEmpty)

        let after = dir.appendingPathComponent("after.mov")
        let second = Box<ExportSensitiveData>()
        try await ProjectExporter.export(project: project, videoURL: video, settings: settings, to: after, cursors: nil, readsAhead: true,
                                         observeSensitiveData: { second.value = $0 })
        #expect(second.value == nil)

        let a = try await decodedFrames(streamed), b = try await decodedFrames(after)
        #expect(a.count == 80)
        #expect(a.count == b.count)
        #expect(a == b)
    }
}
