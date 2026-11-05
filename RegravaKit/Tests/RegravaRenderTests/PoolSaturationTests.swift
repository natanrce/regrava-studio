import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// More media reads at once than there are Swift concurrency threads: every one must finish.
/// A blocking read on each of those threads starves the framework work the reads wait for, and
/// the whole process stalls, so the reads run on threads of their own.
struct PoolSaturationTests {
    /// A 2 s 320×180 movie with moving content, and a 2 s tone.
    private static func makeFixture(in dir: URL) async throws -> (video: URL, audio: URL) {
        let video = dir.appendingPathComponent("recording.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let shade = CGFloat(i % 20) / 20
            let image = CIImage(color: CIColor(red: shade, green: 0.3, blue: 1 - shade)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
            context.render(image, to: buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)

        let audio = dir.appendingPathComponent("microphone.caf")
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        let total = Int(rate * 2)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        pcm.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { pcm.floatChannelData![0][i] = Float(sin(Double(i) / rate * 2 * .pi * 440) * 0.5) }
        try file.write(from: pcm)
        return (video, audio)
    }

    /// Runs `operation` in a detached task and waits for it on a semaphore with a deadline. A
    /// stalled pool cannot even report a failure (that needs its threads too), so a missed
    /// deadline ends the test process with a message instead of hanging it.
    private static func finishes(within seconds: Double, _ what: String, _ operation: @escaping @Sendable () async throws -> Void) -> Error? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        let task = Task.detached {
            do { try await operation() } catch { failure = error }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            task.cancel()
            FileHandle.standardError.write(Data("PoolSaturationTests: \(what) did not finish within \(Int(seconds)) s; the Swift concurrency threads are stalled\n".utf8))
            exit(EXIT_FAILURE)
        }
        return failure
    }

    /// Blocks this test's own thread on purpose: the reads under test must not need it.
    @Test func concurrentReadsFinishWithEveryPoolThreadBusy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regrava-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        nonisolated(unsafe) var fixture: (video: URL, audio: URL)?
        let fixtureError = Self.finishes(within: 60, "writing the fixture") { fixture = try await Self.makeFixture(in: dir) }
        #expect(fixtureError == nil, "\(String(describing: fixtureError))")
        let (video, audio) = try #require(fixture)

        let moves = stride(from: 0.0, through: 2000, by: 16).map { t in
            MouseEvent(kind: .move, timeMs: t, position: Vec2(40 + t / 10, 90))
        }
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 320, height: 180), pointPixelScale: 1, durationMs: 2000, fps: 30),
            mouseEvents: moves,
            style: StyleConfig(aspectRatio: 16.0 / 9)
        )
        project.zooms = [ZoomRange(startMs: 200, endMs: 1500, scale: 2)]
        let sample = project
        let jobs = ProcessInfo.processInfo.activeProcessorCount + 4
        let error = Self.finishes(within: 120, "\(jobs) concurrent reads") {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for job in 0..<jobs {
                    group.addTask {
                        switch job % 7 {
                        case 0:
                            _ = try await CursorHoverDetector.detect(video: video, events: moves, pointPixelScale: 1)
                        case 1:
                            let silence = try await SilenceAnalyzer.analyze(recording: audio, audioTrackIndex: 0, hideDuringSilenceMs: 2000)
                            #expect(silence.chunks.isEmpty)
                        case 2:
                            let levels = try await WaveformReader.levels(url: audio)
                            #expect(!levels.isEmpty)
                        case 3:
                            var settings = ExportSettings.defaults(for: .mp4)
                            settings.fps = 10
                            let output = dir.appendingPathComponent("export-\(job).mp4")
                            try await ProjectExporter.export(project: sample, videoURL: video, settings: settings, to: output, cursors: nil)
                        case 4:
                            let faces = try await CameraFaceDetector.detect(movie: video)
                            #expect(faces.isComplete)
                        case 5:
                            let microphone = try await MicrophoneRenderer.read(audio, trackIndex: 0)
                            #expect(microphone.count > 0)
                        default:
                            let output = dir.appendingPathComponent("export-\(job).gif")
                            try await ProjectExporter.export(project: sample, videoURL: video, settings: .defaults(for: .gif), to: output, cursors: nil)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(error == nil, "\(String(describing: error))")
    }
}
