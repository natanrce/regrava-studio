import AVFoundation
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// SD_EXPORT_BENCH=1 [SD_EXPORT_LOOPS=6] swift test --filter ExportSensitiveDataBenchmark
/// Exports the reference clip (looped) with Hide sensitive data on, once after the complete scan
/// and once alongside it, each from an empty evidence cache, and compares their frames.
struct ExportSensitiveDataBenchmark {
    private func frameHashes(_ url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var hashes: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer) * 4
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var hasher = Hasher()
            for row in 0..<CVPixelBufferGetHeight(buffer) { hasher.combine(bytes: UnsafeRawBufferPointer(start: base + row * rowBytes, count: width)) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            hashes.append(hasher.finalize())
        }
        return hashes
    }

    private func makeBundle(_ dir: URL, name: String, from clip: URL, loops: Int) async throws -> (URL, Project) {
        let bundle = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let video = bundle.appendingPathComponent("recording.mov")
        let source = AVURLAsset(url: clip)
        let track = try #require(try await source.loadTracks(withMediaType: .video).first)
        let duration = try await source.load(.duration)
        let size = try await track.load(.naturalSize)
        let composition = AVMutableComposition()
        let out = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        for loop in 0..<loops {
            try out.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: CMTimeMultiply(duration, multiplier: Int32(loop)))
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: video, as: .mov)
        let total = try await AVURLAsset(url: video).load(.duration).seconds * 1000
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: size.width, height: size.height), pointPixelScale: 2, durationMs: total, fps: 60),
                              mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(100, 100))], style: StyleConfig(aspectRatio: 16.0 / 9))
        project.processing.autoMaskSensitiveData = true
        return (video, project)
    }

    @Test func exportsAlongsideTheScan() async throws {
        guard ProcessInfo.processInfo.environment["SD_EXPORT_BENCH"] == "1", SDTestData.hasClip else { return }
        let loops = Int(ProcessInfo.processInfo.environment["SD_EXPORT_LOOPS"] ?? "6") ?? 6
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-export-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = URL(fileURLWithPath: SDTestData.clip)
        var settings = ExportSettings.defaults(for: .mp4)
        settings.fps = 30

        // The complete scan first, then the export.
        let (afterVideo, project) = try await makeBundle(dir, name: "after.regrava", from: clip, loops: loops)
        let afterBundle = afterVideo.deletingLastPathComponent()
        let start = Date()
        let detections = try await SensitiveDataScans.scan(video: afterVideo, phrases: [], detectFaces: false, bundle: afterBundle) { _ in }
        ProjectExporter.storeSensitiveDataResult(detections, project: project, bundle: afterBundle)
        let scanned = Date()
        let afterOutput = dir.appendingPathComponent("after.mp4")
        try await ProjectExporter.export(project: project, videoURL: afterVideo, settings: settings, to: afterOutput, cursors: nil)
        let afterSeconds = Date().timeIntervalSince(start)
        print("SD-EXPORT after scan: scan \(scanned.timeIntervalSince(start))s + render \(Date().timeIntervalSince(scanned))s = \(afterSeconds)s, \(detections.count) detections, \(project.recording.durationMs / 1000)s video")

        // The export alongside the scan.
        let (streamVideo, streamProject) = try await makeBundle(dir, name: "streaming.regrava", from: clip, loops: loops)
        let streamOutput = dir.appendingPathComponent("streaming.mp4")
        let observed = ExportObservation()
        let streamStart = Date()
        try await ProjectExporter.export(project: streamProject, videoURL: streamVideo, settings: settings, to: streamOutput, cursors: nil, readsAhead: true,
                                         observeSensitiveData: { observed.set($0) })
        let streamSeconds = Date().timeIntervalSince(streamStart)
        print("SD-EXPORT alongside the scan: \(streamSeconds)s, \(observed.source?.usedPartialCount ?? 0) partial results drawn from")

        let afterResult = SensitiveDataScan.load(bundle: afterBundle)?.detections ?? []
        let streamBundle = streamVideo.deletingLastPathComponent()
        let streamResult = SensitiveDataScan.load(bundle: streamBundle)?.detections ?? []
        print("SD-EXPORT the two scans found the same: \(afterResult == streamResult) (\(afterResult.count) / \(streamResult.count))")

        // The same project exported again, now from its complete result.
        let againOutput = dir.appendingPathComponent("again.mp4")
        try await ProjectExporter.export(project: streamProject, videoURL: streamVideo, settings: settings, to: againOutput, cursors: nil)
        let a = try await frameHashes(againOutput), b = try await frameHashes(streamOutput)
        print("SD-EXPORT frames \(a.count) / \(b.count), identical to the export after the complete scan: \(a == b)")
        #expect(a == b)
    }
}

private final class ExportObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ExportSensitiveData?
    var source: ExportSensitiveData? { lock.withLock { stored } }
    func set(_ source: ExportSensitiveData) { lock.withLock { stored = source } }
}
