import Foundation
import Testing
@testable import RegravaRender
import RegravaCore
import CoreVideo

/// SCRUB_BENCH=/path/to/movie swift test --filter VideoScrubberBenchmark
struct VideoScrubberBenchmark {
    @Test func sweep() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRUB_BENCH"] else { return }
        let scrubber = VideoScrubber(url: URL(fileURLWithPath: path))
        // A fast hover sweep: 120 Hz pointer, 60 ms of video per event.
        var lags: [Double] = []
        var exact = 0
        var distinct = Set<Double>()
        let start = Date()
        for step in 0..<240 {
            let target = 20_000 + Double(step) * 60
            scrubber.demand(target)
            try await Task.sleep(nanoseconds: 8_333_333)
            if let frame = scrubber.frame(at: target) {
                lags.append(target - frame.ms)
                distinct.insert(frame.ms)
                if target - frame.ms < 20 { exact += 1 }
            } else { lags.append(.infinity) }
        }
        let elapsed = Date().timeIntervalSince(start)
        let sorted = lags.sorted()
        print("SWEEP elapsed \(elapsed)s, distinct frames shown \(distinct.count), exact(<20ms) \(exact)/240, median lag \(sorted[120]) ms, p90 \(sorted[216]) ms")
        // Random jumps.
        var waits: [Double] = []
        for i in 0..<20 {
            let target = Double((i * 7919) % 200) * 1000 + 500
            let t0 = Date()
            scrubber.demand(target)
            while (scrubber.frame(at: target).map { target - $0.ms } ?? .infinity) > 20 || (scrubber.frame(at: target).map { target - $0.ms } ?? -1) < 0 {
                try await Task.sleep(nanoseconds: 1_000_000)
                if Date().timeIntervalSince(t0) > 2 { break }
            }
            waits.append(Date().timeIntervalSince(t0) * 1000)
        }
        print("JUMPS ms", waits.map { Int($0) })
        scrubber.close()
    }
}

struct ScrubPreviewSmoke {
    @Test @MainActor func composesAFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCRUB_BENCH"] else { return }
        let project = Project(recording: RecordingInfo(videoSize: Size2(width: 2880, height: 1800), pointPixelScale: 2, durationMs: 250_000, fps: 60), mouseEvents: [])
        let state = RenderState(project: project)
        let preview = ScrubPreview(state: state, screenURL: URL(fileURLWithPath: path), cameraURL: nil, cameraOffsetMs: 0, resolver: project.resolver, canvas: project.canvasSize, output: Size2(width: 1280, height: 800))
        nonisolated(unsafe) var images = 0
        nonisolated(unsafe) var size = CGSize.zero
        preview.onImage = { buffer in images += 1; size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
        let t0 = Date()
        for i in 0..<120 {
            preview.show(playbackMs: 30_000 + Double(i) * 50)
            try await Task.sleep(nanoseconds: 8_333_333)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        print("PREVIEW images \(images) in \(Date().timeIntervalSince(t0))s size \(size)")
        #expect(images > 0)
        preview.close()
    }
}
