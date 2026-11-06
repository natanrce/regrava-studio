@preconcurrency import AVFoundation
import Foundation
import RegravaCore

/// The playback sample format as Core Audio and AVFoundation describe it.
enum MixPlaybackFormat {
    static let avFormat = AVAudioFormat(standardFormatWithSampleRate: MixFormat.sampleRate, channels: AVAudioChannelCount(MixFormat.channelCount))!
    static var streamDescription: AudioStreamBasicDescription { avFormat.streamDescription.pointee }
}

/// Reads a source from a position on, as stereo 48 kHz.
protocol MixSourceReader: AnyObject {
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int)
    /// Set once reading failed.
    var failure: String? { get }
}

/// The opened sources of a mix, kept while their files stay the same. Short sources are
/// decoded into memory.
final class MixSourceCatalog: @unchecked Sendable {
    /// Sources up to this long are kept decoded.
    static let memoryLimitSeconds = 5.0

    struct Key: Hashable {
        var source: AudioMixSource
        var modified: Date?
        var size: Int?
    }

    final class Source {
        let source: AudioMixSource
        let asset: AVURLAsset
        let durationSeconds: Double
        let memory: (left: [Float], right: [Float])?

        init(source: AudioMixSource, asset: AVURLAsset, durationSeconds: Double, memory: (left: [Float], right: [Float])?) {
            self.source = source
            self.asset = asset
            self.durationSeconds = durationSeconds
            self.memory = memory
        }
    }

    private let lock = NSLock()
    private var sources: [Key: Source] = [:]

    func source(at source: AudioMixSource) throws -> Source {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else {
            throw MixError.source(path: source.path, message: "no such file")
        }
        let key = Key(source: source, modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue)
        lock.lock()
        let cached = sources[key]
        lock.unlock()
        if let cached { return cached }
        let asset = AVURLAsset(url: URL(fileURLWithPath: source.path))
        let tracks = Self.audioTracks(of: asset)
        guard source.audioTrack < tracks.count else { throw MixError.source(path: source.path, message: "has no audio track") }
        let track = tracks[source.audioTrack]
        let range = Self.timeRange(of: track)
        let duration = CMTimeAdd(range.start, range.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MixError.source(path: source.path, message: "no audio") }
        var memory: (left: [Float], right: [Float])?
        if !(duration > Self.memoryLimitSeconds) {
            let reader = try AssetSourceReader(asset: asset, track: track, path: source.path, startSeconds: 0)
            let frames = Int(max(MixFormat.frames(seconds: duration), 0))
            var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    if frames > 0 { reader.read(left: l.baseAddress!, right: r.baseAddress!, count: frames) }
                }
            }
            memory = (left, right)
        }
        let opened = Source(source: source, asset: asset, durationSeconds: duration, memory: memory)
        lock.lock()
        sources[key] = opened
        lock.unlock()
        return opened
    }

    /// Forgets sources not in `keeping`.
    func retainOnly(_ keeping: Set<AudioMixSource>) {
        lock.lock()
        sources = sources.filter { keeping.contains($0.key.source) }
        lock.unlock()
    }

    static func audioTracks(of asset: AVURLAsset) -> [AVAssetTrack] {
        blocking { (try? await asset.loadTracks(withMediaType: .audio)) ?? [] }
    }

    static func timeRange(of track: AVAssetTrack) -> CMTimeRange {
        blocking { (try? await track.load(.timeRange)) ?? .invalid }
    }

    /// Waits for an async asset query on the calling (mixing) thread.
    private static func blocking<T>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = BlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

private final class BlockingBox<T>: @unchecked Sendable {
    var value: T?
}

/// A reader for a source from `startSeconds` on.
func makeReader(for source: MixSourceCatalog.Source, startSeconds: Double) throws -> MixSourceReader {
    if let memory = source.memory {
        return MemorySourceReader(left: memory.left, right: memory.right, startFrame: max(Int(MixFormat.frames(seconds: startSeconds)), 0))
    }
    let tracks = MixSourceCatalog.audioTracks(of: source.asset)
    guard source.source.audioTrack < tracks.count else { throw MixError.source(path: source.source.path, message: "has no audio track") }
    return try AssetSourceReader(asset: source.asset, track: tracks[source.source.audioTrack], path: source.source.path, startSeconds: startSeconds)
}

/// Decodes a file's audio track from a time on; silence after its end.
final class AssetSourceReader: MixSourceReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let startSeconds: Double
    /// Interleaved stereo of the last decoded buffer, and the next frame to hand out.
    private var pending: [Float] = []
    private var pendingIndex = 0
    private var sawFirstBuffer = false
    private var finished = false
    private(set) var failure: String?

    init(asset: AVURLAsset, track: AVAssetTrack, path: String, startSeconds: Double) throws {
        self.startSeconds = max(startSeconds, 0)
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MixError.source(path: path, message: error.localizedDescription)
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVSampleRateKey: MixFormat.sampleRate,
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        if self.startSeconds > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: self.startSeconds, preferredTimescale: 48_000), end: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw MixError.source(path: path, message: reader.error?.localizedDescription ?? "the decoder would not start")
        }
    }

    deinit { reader.cancelReading() }

    private var pendingFrames: Int { pending.count / 2 }

    /// Decodes the next buffer; false at the end.
    private func fillPending() -> Bool {
        guard !finished else { return false }
        guard let sample = output.copyNextSampleBuffer() else {
            finished = true
            if reader.status == .failed { failure = reader.error?.localizedDescription ?? "failed decoding" }
            return false
        }
        guard CMSampleBufferGetNumSamples(sample) > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return true }
        let length = CMBlockBufferGetDataLength(block)
        pending = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        pending.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        pendingIndex = 0
        if !sawFirstBuffer {
            sawFirstBuffer = true
            // Line the first buffer up with the start: skip what is before it, pad a late start.
            let offset = MixFormat.frames(seconds: startSeconds - CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if offset < 1 {
                if offset < 0 { pending = [Float](repeating: 0, count: Int(-offset) * 2) + pending }
            } else {
                pendingIndex = min(Int(offset), pendingFrames)
            }
        }
        return true
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            while pendingIndex >= pendingFrames {
                guard fillPending() else {
                    left.advanced(by: done).update(repeating: 0, count: count - done)
                    right.advanced(by: done).update(repeating: 0, count: count - done)
                    return
                }
            }
            let n = min(pendingFrames - pendingIndex, count - done)
            pending.withUnsafeBufferPointer { p in
                for i in 0..<n {
                    left[done + i] = p[2 * (pendingIndex + i)]
                    right[done + i] = p[2 * (pendingIndex + i) + 1]
                }
            }
            pendingIndex += n
            done += n
        }
    }
}

/// Reads a decoded source; silence after its end.
final class MemorySourceReader: MixSourceReader {
    private let left: [Float]
    private let right: [Float]
    private var position: Int
    var failure: String? { nil }

    init(left: [Float], right: [Float], startFrame: Int) {
        self.left = left
        self.right = right
        position = startFrame
    }

    func read(left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>, count: Int) {
        let n = max(min(left.count - position, count), 0)
        if n > 0 {
            left.withUnsafeBufferPointer { out.update(from: $0.baseAddress! + position, count: n) }
            right.withUnsafeBufferPointer { outRight.update(from: $0.baseAddress! + position, count: n) }
        }
        if count > n {
            out.advanced(by: n).update(repeating: 0, count: count - n)
            outRight.advanced(by: n).update(repeating: 0, count: count - n)
        }
        position += count
    }
}
