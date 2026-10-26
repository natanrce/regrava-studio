import AVFoundation
import Foundation
import Testing
import RegravaCore
@testable import RegravaRender

/// SCAN_BENCH=/path/to/movie [SCAN_START=s] [SCAN_FACES=0] swift test --filter SensitiveDataScannerBenchmark
struct SensitiveDataScannerBenchmark {
    @Test func scansAClip() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_BENCH"] else { return }
        let source = AVURLAsset(url: URL(fileURLWithPath: path))
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).mov")
        let session = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough)!
        session.timeRange = CMTimeRange(start: CMTime(seconds: Double(ProcessInfo.processInfo.environment["SCAN_START"] ?? "0") ?? 0, preferredTimescale: 600), duration: CMTime(seconds: 15, preferredTimescale: 600))
        try await session.export(to: clip, as: .mov)
        defer { try? FileManager.default.removeItem(at: clip) }
        let t0 = Date()
        let detections = try await SensitiveDataScanner.scan(video: clip, phrases: ["Natan"], detectFaces: ProcessInfo.processInfo.environment["SCAN_FACES"] != "0") { _, _ in }
        print("SCAN \(Date().timeIntervalSince(t0))s, \(detections.count) detections")
        for d in detections.prefix(40) { print("  \(d.kind) \(Int(d.startMs))-\(Int(d.endMs)) \(d.text.prefix(40)) \(d.keyframes.first.map { "\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))" } ?? "")") }
    }
}
