import AVFoundation
import CoreVideo
import Foundation
import ScreenCaptureKit
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

    /// A session whose picture stood still at the end runs until the session's end time.
    @Test func finishingAtAnEndTimeHoldsTheLastFrame() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try SegmentedWriter(directory: dir, name: "channel-1-display-0", mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ], holdsLastSample: true)
        try await RecordingFinalizerTests.frames(writer, from: 100, seconds: 3)
        await writer.finish(endTime: CMTime(seconds: 105.5, preferredTimescale: 1_000_000_000))
        let out = dir.appendingPathComponent("flat.mp4")
        try RecordingFolder.flatten(writer.playlistURL, to: out)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        let range = try await asset.loadTracks(withMediaType: .video)[0].load(.timeRange)
        print("END-TIME duration \(duration) track \(range.duration.seconds)")
        #expect(duration >= 5.5 && duration < 5.6)
        #expect(range.duration.seconds >= 5.5 && range.duration.seconds < 5.6)
    }

    /// A session that begins while the screen stands still starts at once, with the latest
    /// picture moved to its start.
    @Test func sessionOnAStillScreenStartsWithTheLatestPicture() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let channels = StreamChannels()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescriptionOut: &format)
        let before = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 2, preferredTimescale: 600))
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: before, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        channels.queue.sync { channels.stream(stream, didOutputSampleBuffer: sample!, of: .screen) }

        let display = try SegmentedWriter(directory: dir, name: "channel-1-display-1", mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ], holdsLastSample: true)
        let requested = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let start = try await channels.attach([.screen: display])
        print("STILL start \(start) requested \(requested) frame \(before.seconds)")
        #expect(start >= requested && start - requested < 0.5)
        #expect(display.startTime == start)
        _ = await channels.detach()
        await display.finish(endTime: CMTime(seconds: start + 1, preferredTimescale: 1_000_000_000))
        let out = dir.appendingPathComponent("flat.mp4")
        try RecordingFolder.flatten(display.playlistURL, to: out)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        print("STILL duration \(duration)")
        #expect(duration >= 1)
    }

    /// While no new picture arrives the last one is written again every second.
    @Test func stillScreenRepeatsTheLastPictureEverySecond() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let channels = StreamChannels()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescriptionOut: &format)
        let display = try SegmentedWriter(directory: dir, name: "channel-1-display-0", mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        async let started = channels.attach([.screen: display])
        try await Task.sleep(nanoseconds: 100_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        channels.queue.async { channels.stream(stream, didOutputSampleBuffer: sample!, of: .screen) }
        let start = try await started
        #expect(abs(start - timing.presentationTimeStamp.seconds) < 0.001)
        try await Task.sleep(nanoseconds: 2_400_000_000)
        _ = await channels.detach()
        channels.reset()
        await display.finish()
        let out = dir.appendingPathComponent("flat.mp4")
        try RecordingFolder.flatten(display.playlistURL, to: out)
        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let next = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(next) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(next).seconds) }
        }
        times = times.map { $0 - (times.first ?? 0) }
        print("REPEAT times \(times)")
        // The test's wait can stretch on a busy machine, so check the spacing, not the count.
        #expect(times.count >= 3)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 0.99 && $0 < 1.2 }, "\(gaps)")
    }
}
