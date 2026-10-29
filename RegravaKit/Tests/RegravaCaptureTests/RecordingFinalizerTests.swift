import AVFoundation
import CoreVideo
import Foundation
import Testing
import RegravaCore
@testable import RegravaCapture

@MainActor
struct RecordingFinalizerTests {
    static func frames(_ writer: SegmentedWriter, from start: Double, seconds: Double) async throws {
        var format: CMVideoFormatDescription?
        for i in 0..<Int(seconds * 30) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescriptionOut: &format) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: start + Double(i) / 30, preferredTimescale: 6000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
            while !writer.append(sample!) { try await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    /// Two sessions, the second cut short by a "crash" (never finished): the folder still
    /// finalizes, paused time is removed and events land on the joined timeline.
    @Test func finalizesAnInterruptedFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try RecordingJournal(folder: folder)
        journal.update { $0.videoSize = Size2(width: 320, height: 200); $0.fps = 30 }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200]
        let first = try SegmentedWriter(directory: folder, name: "channel-1-display-0", mediaType: .video, outputSettings: settings)
        try await Self.frames(first, from: 100, seconds: 3)
        await first.finish()
        let second = try SegmentedWriter(directory: folder, name: "channel-1-display-1", mediaType: .video, outputSettings: settings)
        try await Self.frames(second, from: 110, seconds: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        journal.update {
            $0.sessions = [
                .init(index: 0, startUptime: 100, endUptime: 103, channels: [.init(source: "display", playlist: "channel-1-display-0", startUptime: 100)]),
                .init(index: 1, startUptime: 110, endUptime: nil, channels: [.init(source: "display", playlist: "channel-1-display-1", startUptime: 110)]),
            ]
            $0.markerUptimes = [111]
        }
        journal.record(MouseTracker.Sample(kind: .move, uptime: 101, location: CGPoint(x: 10, y: 20), button: 0, cursorID: "arrow", modifiers: []))
        journal.record(MouseTracker.Sample(kind: .move, uptime: 105, location: CGPoint(x: 10, y: 20), button: 0, cursorID: "arrow", modifiers: []))
        journal.record(MouseTracker.Sample(kind: .down, uptime: 112, location: CGPoint(x: 30, y: 40), button: 0, cursorID: "arrow", modifiers: []))
        try await Task.sleep(nanoseconds: 1_300_000_000) // one commit, no close: the array has no end
        let result = try await RecordingFinalizer.finalize(folder: folder)
        print("FINAL duration \(result.durationMs) events \(result.mouseEvents.map(\.timeMs)) markers \(result.markersMs)")
        #expect(result.durationMs > 6500 && result.durationMs < 8100)
        #expect(result.mouseEvents.count == 2) // the one during the pause is dropped
        #expect(abs(result.mouseEvents[1].timeMs - 5000) < 50)
        #expect(abs(result.markersMs[0] - 4000) < 50)
        let asset = AVURLAsset(url: result.videoURL)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    }

    /// The picture stood still for the last two seconds: the session still lasts until it
    /// ended, and so do its events.
    @Test func sessionLastsUntilItsEndTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try RecordingJournal(folder: folder)
        journal.update { $0.videoSize = Size2(width: 320, height: 200); $0.fps = 30 }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200]
        let display = try SegmentedWriter(directory: folder, name: "channel-1-display-0", mediaType: .video, outputSettings: settings, holdsLastSample: true)
        try await Self.frames(display, from: 100, seconds: 3)
        await display.finish(endTime: CMTime(seconds: 105, preferredTimescale: 1_000_000_000))
        journal.update {
            $0.sessions = [.init(index: 0, startUptime: 100, endUptime: 105, channels: [.init(source: "display", playlist: "channel-1-display-0", startUptime: 100)])]
        }
        journal.record(MouseTracker.Sample(kind: .down, uptime: 104.5, location: CGPoint(x: 30, y: 40), button: 0, cursorID: "arrow", modifiers: []))
        journal.close()
        let result = try await RecordingFinalizer.finalize(folder: folder)
        let duration = try await AVURLAsset(url: result.videoURL).load(.duration).seconds
        print("END-TIME final \(result.durationMs) movie \(duration) events \(result.mouseEvents.map(\.timeMs))")
        #expect(abs(result.durationMs - 5000) < 1)
        #expect(abs(duration - 5) < 0.05)
        #expect(result.mouseEvents.count == 1)
        #expect(abs((result.mouseEvents.first?.timeMs ?? 0) - 4500) < 1)
    }
}
