@preconcurrency import AVFoundation
import Foundation

/// One channel of a recording written as it records: an fMP4 HLS playlist `<name>.m3u8` with
/// its init segment `<name>-0000.mp4` and `<name>-NNNN.m4s` media segments, so a crash loses
/// at most the last unflushed segment. The init segment followed by the media segments is
/// itself a readable fragmented MP4 (`RecordingFolder.flatten`).
final class SegmentedWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    /// `#EXT-X-TARGETDURATION:2` on the playlists.
    static let segmentSeconds = 2.0

    /// AAC 48 kHz stereo, as the recordings' audio channels are written.
    static var audioSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    let directory: URL
    let name: String
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segmentIndex = 0
    /// The playlist's `#EXTINF` lines so far, grown as segments are written.
    private var entryLines = ""
    private var initFile: String?
    private let lock = NSLock()
    /// Host time (seconds) of the first sample written.
    private(set) var startTime: Double?
    /// Keeps the last sample so `finish(endTime:)` can hold the picture until the end.
    private let holdsLastSample: Bool
    private var lastSample: CMSampleBuffer?

    var playlistURL: URL { directory.appendingPathComponent("\(name).m3u8") }

    init(directory: URL, name: String, mediaType: AVMediaType, outputSettings: [String: Any]?, holdsLastSample: Bool = false) throws {
        self.directory = directory
        self.name = name
        self.holdsLastSample = holdsLastSample
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.segmentSeconds, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        adaptor = mediaType == .video ? AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil) : nil
        super.init()
        writer.delegate = self
        guard writer.canAdd(input) else { throw CaptureError.failed("Could not record \(name).") }
        writer.add(input)
    }

    /// Appends a sample; the first one starts the file at its time.
    @discardableResult
    func append(_ sample: CMSampleBuffer) -> Bool {
        guard begin(at: CMSampleBufferGetPresentationTimeStamp(sample)), input.isReadyForMoreMediaData else { return false }
        lastTime = CMSampleBufferGetPresentationTimeStamp(sample)
        if holdsLastSample { lastSample = sample }
        return input.append(sample)
    }

    /// A frame made here (a turned device frame), at `time`.
    @discardableResult
    func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard let adaptor, begin(at: time), input.isReadyForMoreMediaData else { return false }
        lastTime = time
        return adaptor.append(buffer, withPresentationTime: time)
    }

    /// Time of the last sample written.
    private(set) var lastTime: CMTime?
    /// Called once with the first sample's host time.
    var onStart: ((Double) -> Void)?

    private func begin(at time: CMTime) -> Bool {
        if startTime == nil {
            writer.initialSegmentStartTime = time
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: time)
            startTime = time.seconds
            writePlaylist(ended: false)
            onStart?(time.seconds)
        }
        return writer.status == .writing
    }

    /// Flushes the last segment and closes the playlist (`#EXT-X-ENDLIST`). With `endTime` (and
    /// `holdsLastSample`) the last picture is repeated at `endTime`, so a picture that stood still
    /// at the end still lasts until the session ended.
    func finish(endTime: CMTime? = nil) async {
        guard startTime != nil, writer.status == .writing else { return }
        if let endTime, let last = lastSample, let lastTime, endTime > lastTime {
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(last), presentationTimeStamp: endTime, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy {
                for _ in 0 ..< 100 where !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
                if input.isReadyForMoreMediaData { input.append(copy) }
            }
        }
        lastSample = nil
        input.markAsFinished()
        await writer.finishWriting()
        writePlaylist(ended: true)
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        defer { lock.unlock() }
        let file: String
        switch segmentType {
        case .initialization:
            file = "\(name)-0000.mp4"
            initFile = file
        case .separable:
            segmentIndex += 1
            file = String(format: "%@-%04d.m4s", name, segmentIndex)
            let seconds = segmentReport?.trackReports.first.map { $0.duration.seconds } ?? Self.segmentSeconds
            entryLines += String(format: "#EXTINF:%1.5f,\n", seconds) + file + "\n"
        @unknown default:
            return
        }
        // Written beside and moved in, so a listed segment is always complete.
        let url = directory.appendingPathComponent(file)
        let partial = directory.appendingPathComponent(".\(file).part")
        do {
            try segmentData.write(to: partial)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            return
        }
        writePlaylistLocked(ended: false)
    }

    private func writePlaylist(ended: Bool) {
        lock.lock()
        writePlaylistLocked(ended: ended)
        lock.unlock()
    }

    /// The header.
    private func writePlaylistLocked(ended: Bool) {
        var text = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:\(Int(Self.segmentSeconds))\n#EXT-X-VERSION:6\n#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        if let initFile { text += "#EXT-X-MAP:URI=\"\(initFile)\"\n" }
        text += entryLines
        if ended { text += "#EXT-X-ENDLIST\n" }
        try? text.write(to: playlistURL, atomically: true, encoding: .utf8)
    }
}
