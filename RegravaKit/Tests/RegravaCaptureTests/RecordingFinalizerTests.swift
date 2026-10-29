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

    /// 48 kHz stereo PCM (a tone) on the host clock, in 1024-frame buffers.
    static func sound(_ writer: SegmentedWriter, from start: Double, seconds: Double) async throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let frames = 1024
        let total = Int(seconds * 48_000)
        var written = 0
        while written < total {
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 8, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frames * 8, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            var values = [Float](repeating: 0, count: frames * 2)
            for i in 0 ..< frames { let v = Float(sin(Double(written + i) * 2 * .pi * 440 / 48_000)) * 0.2; values[2 * i] = v; values[2 * i + 1] = v }
            values.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 8) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(Int(start * 48_000) + written), timescale: 48_000),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            while !writer.append(sample!) { try await Task.sleep(nanoseconds: 2_000_000) }
            written += frames
        }
    }

    /// The selected apps' sound runs through the pause and is cut to the two sessions.
    @Test func cutsContinuousSoundToTheSessions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try RecordingJournal(folder: folder)
        journal.update { $0.videoSize = Size2(width: 320, height: 200); $0.fps = 30 }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200]
        let first = try SegmentedWriter(directory: folder, name: "channel-1-display-0", mediaType: .video, outputSettings: settings)
        try await Self.frames(first, from: 100, seconds: 3)
        await first.finish()
        let second = try SegmentedWriter(directory: folder, name: "channel-1-display-1", mediaType: .video, outputSettings: settings)
        try await Self.frames(second, from: 110, seconds: 3)
        await second.finish()
        let apps = try SegmentedWriter(directory: folder, name: "channel-4-system-audio-apps-0", mediaType: .audio, outputSettings: SegmentedWriter.audioSettings)
        try await Self.sound(apps, from: 99, seconds: 13)
        await apps.finish()
        journal.update {
            $0.sessions = [
                .init(index: 0, startUptime: 100, endUptime: 103, channels: [.init(source: "display", playlist: "channel-1-display-0", startUptime: 100)]),
                .init(index: 1, startUptime: 110, endUptime: 113, channels: [.init(source: "display", playlist: "channel-1-display-1", startUptime: 110)]),
            ]
            $0.continuous = [.init(source: AudioSource.systemAudio.rawValue, playlist: "channel-4-system-audio-apps-0", startUptime: 99)]
        }
        journal.close()
        let result = try await RecordingFinalizer.finalize(folder: folder)
        let asset = AVURLAsset(url: result.videoURL)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let range = try await audio.first?.load(.timeRange)
        print("CONTINUOUS sources \(result.audioSources) tracks \(audio.count) range \(range.map { ($0.start.seconds, $0.duration.seconds) } as Any) movie \(try await asset.load(.duration).seconds)")
        #expect(result.audioSources == [.systemAudio])
        #expect(audio.count == 1)
        #expect(abs((range?.duration.seconds ?? 0) - 5) < 0.1)
    }

    /// Closed, open, and torn event logs all read back every whole object.
    @Test func readsEventLogsWhateverTheirEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = { (t: Int) in "{\"kind\":\"down\",\"uptime\":\(t),\"character\":\"a\",\"modifiers\":[],\"isARepeat\":false}," }
        for text in ["[\n\(line(1))\n\(line(2))\n]\n", "[\n\(line(1))\n\(line(2))\n", "[\n\(line(1))\n\(line(2))\n{\"kind\":\"do", "[\n]\n", "[\n"] {
            try Data(text.utf8).write(to: url)
            let keys = StreamingJSONWriter.read(JournalKey.self, from: url)
            #expect(keys.map(\.uptime) == (text.count > 6 ? [1, 2] : []), "\(text)")
        }
    }
}
