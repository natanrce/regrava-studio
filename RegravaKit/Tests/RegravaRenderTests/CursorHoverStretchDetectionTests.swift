import AVFoundation
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Hover detection read stretch by stretch: the stretches find what one read finds, finished
/// stretches survive an interruption, and the next detection reads only the rest.
@Suite(.serialized)
struct CursorHoverStretchDetectionTests {
    static let width = 160, height = 90, fps = 10
    static let durationMs = 45_000.0
    /// Moments a block lights up under the cursor, one of them just past a stretch boundary.
    static let highlightsMs: [Double] = [5_000, 12_000, 20_300, 31_000, 41_500]

    /// The cursor sweeps left and right across the frame at 60 pt/s.
    static func cursor(at t: Double) -> Vec2 {
        let travel = 100.0, phase = (t / 1000 * 60).truncatingRemainder(dividingBy: 2 * travel)
        return Vec2(30 + (phase < travel ? phase : 2 * travel - phase), 45)
    }

    static let moves = stride(from: 0.0, through: durationMs, by: 50).map { MouseEvent(kind: .move, timeMs: $0, position: cursor(at: $0)) }

    /// A grey screen where a 40 px block lights up around the cursor for a second at each highlight.
    static func makeVideo(in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("screen.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(durationMs) * fps / 1000
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let t = Double(i) * 1000 / Double(fps)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let lit = highlightsMs.first { t >= $0 && t < $0 + 1000 }.map { cursor(at: $0) }
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * stride + x * 4
                    let inBlock = lit.map { abs(Double(x) - $0.x) <= 20 && abs(Double(y) - $0.y) <= 20 } ?? false
                    (p[0], p[1], p[2], p[3]) = inBlock ? (40, 190, 230, 255) : (70, 70, 70, 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regrava-hover-stretches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    @Test func stretchesFindWhatOneReadOfTheWholeRecordingFinds() async throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await Self.makeVideo(in: dir)
        let whole = try await CursorHoverDetector.detect(video: video, events: Self.moves, pointPixelScale: 1)
        #expect(whole.count >= 3)
        var stretched: [Double] = []
        for stretch in CursorHovers.stretches(durationMs: Self.durationMs) {
            stretched += try await CursorHoverDetector.detect(video: video, events: Self.moves, pointPixelScale: 1, rangeMs: stretch.startMs..<stretch.endMs)
        }
        #expect(stretched == whole)
        // Each stretch reports only its own changes.
        let middle = try await CursorHoverDetector.detect(video: video, events: Self.moves, pointPixelScale: 1, rangeMs: 20_000..<40_000)
        #expect(middle == whole.filter { $0 >= 20_000 && $0 < 40_000 } && !middle.isEmpty)
    }

    @Test func anInterruptedDetectionResumesWithTheSameResult() async throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await Self.makeVideo(in: dir)
        let grid = CursorHovers.stretches(durationMs: Self.durationMs)

        // Uninterrupted.
        let fresh = dir.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let reference = try await CursorHoverDetector.detectStretches(video: video, events: Self.moves, pointPixelScale: 1, durationMs: Self.durationMs, bundle: fresh)
        #expect(reference.chunks.map(\.stretch) == grid)
        #expect(CursorHovers.load(bundle: fresh) == reference)

        // Cancelled once the first stretch is stored.
        let bundle = dir.appendingPathComponent("interrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let interrupted = Task {
            try await CursorHoverDetector.detectStretches(video: video, events: Self.moves, pointPixelScale: 1, durationMs: Self.durationMs, bundle: bundle,
                                                          onStretch: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        await #expect(throws: CancellationError.self) { _ = try await interrupted.value }
        #expect(!FileManager.default.fileExists(atPath: CursorHovers.url(bundle: bundle).path))
        let partial = try #require(CursorHovers.load(bundle: bundle))
        #expect(!partial.chunks.isEmpty && partial.chunks.count < grid.count)
        #expect(!partial.covers(durationMs: Self.durationMs))
        for chunk in partial.chunks {
            #expect(chunk.result == reference.chunks.first { $0.stretch == chunk.stretch }?.result)
        }

        // Resumed: only the missing stretches are read.
        let read = Counter()
        let resumed = try await CursorHoverDetector.detectStretches(video: video, events: Self.moves, pointPixelScale: 1, durationMs: Self.durationMs, bundle: bundle,
                                                                    onStretch: { _ in _ = read.increment() })
        #expect(read.count == grid.count - partial.chunks.count)
        #expect(resumed == reference)
        #expect(CursorHovers.load(bundle: bundle) == reference)
        #expect(resumed.timesMs == (try await CursorHoverDetector.detect(video: video, events: Self.moves, pointPixelScale: 1)))
    }

    @Test func callersJoinOneRunningDetection() async throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await Self.makeVideo(in: dir)
        let project = Project(recording: RecordingInfo(videoSize: Size2(width: Double(Self.width), height: Double(Self.height)), pointPixelScale: 1, durationMs: Self.durationMs, fps: 10),
                              mouseEvents: Self.moves)
        let read = Counter()
        async let first = CursorHoverDetections.detect(project: project, video: video, bundle: dir, onStretch: { _ in _ = read.increment() })
        async let second = CursorHoverDetections.detect(project: project, video: video, bundle: dir)
        let (a, b) = try await (first, second)
        #expect(a == b && a.covers(durationMs: Self.durationMs))
        #expect(read.count == CursorHovers.stretches(durationMs: Self.durationMs).count)
    }
}
