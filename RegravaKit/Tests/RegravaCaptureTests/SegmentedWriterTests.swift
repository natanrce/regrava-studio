import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import RegravaCapture

struct SegmentedWriterTests {
    /// A writer that never finishes (a crash) still leaves a readable movie once flattened.
    @Test func unfinishedPlaylistFlattensToAReadableMovie() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try SegmentedWriter(directory: dir, name: "channel-1-display-0", mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        var format: CMVideoFormatDescription?
        for i in 0..<(60 * 7) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(i % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: CMTimeValue(1000 * 60 + i), timescale: 60), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
            while !writer.append(sample!) { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        // No finish(): flatten what is on disk.
        let files = RecordingFolder.playlistFiles(writer.playlistURL)
        let out = dir.appendingPathComponent("flat.mp4")
        try RecordingFolder.flatten(writer.playlistURL, to: out)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let range = try await tracks[0].load(.timeRange)
        print("RANGE start \(range.start.seconds) dur \(range.duration.seconds)")
        print("SEGMENTS \(files?.segments.count ?? -1) ended \(files?.ended ?? false) flat duration \(duration) tracks \(tracks.count)")
        #expect(tracks.count == 1)
        #expect(duration >= 4)
        // A clean finish lists the rest and closes the playlist.
        await writer.finish()
        let ended = RecordingFolder.playlistFiles(writer.playlistURL)
        try RecordingFolder.flatten(writer.playlistURL, to: out)
        let full = try await AVURLAsset(url: out).load(.duration).seconds
        print("FINISHED segments \(ended?.segments.count ?? -1) ended \(ended?.ended ?? false) duration \(full)")
        #expect(ended?.ended == true)
        #expect(abs(full - 7) < 0.2)
    }
}
