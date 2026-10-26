@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension SD {
    /// Decoded frames of one chunk. Frames nothing else depends on are only decoded when asked for
    /// (or when they look like an event); reference frames are always decoded. Streams with reordered
    /// frames, or whose format no decoder session takes, are decoded by an asset reader instead.
    final class ChunkFrames {
        let samples: VideoSampleReader?
        var decodingReader: (reader: AVAssetReader, output: AVAssetReaderTrackOutput)?
        var session: DecoderSession?
        var readerToken: AssetReaderCensusToken?
        var isDecodedByReader = false
        var hasCheckedStream = false
        let makeDecodingReader: (() throws -> (AVAssetReader, AVAssetReaderTrackOutput))?
        let path: String
        let purpose: String
        var decodedCount = 0
        var skippedCount = 0
        var eventCount = 0
        var failure: String?
        var recentSizes: [Int] = []

        init(samples: VideoSampleReader?, failure: String?, makeDecodingReader: (() throws -> (AVAssetReader, AVAssetReaderTrackOutput))?,
             path: String, purpose: String) {
            self.samples = samples
            self.failure = failure
            self.makeDecodingReader = makeDecodingReader
            self.path = path
            self.purpose = purpose
        }

        /// The next frame the caller needs, with its time in ms and whether it is an event frame.
        func next(isNeeded: (Double) -> Bool) -> (CVPixelBuffer, Double, isEvent: Bool)? {
            while let sample = nextSample() {
                let ms = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
                let isEvent = noteSize(of: sample)
                if isDecodedByReader {
                    if let buffer = CMSampleBufferGetImageBuffer(sample) {
                        decodedCount += 1
                        return (buffer, ms, isEvent)
                    }
                    continue
                }
                if !hasCheckedStream {
                    hasCheckedStream = true
                    let dts = CMSampleBufferGetDecodeTimeStamp(sample)
                    var isUsable = false
                    if !(dts.isValid && dts != CMSampleBufferGetPresentationTimeStamp(sample)),
                       let format = CMSampleBufferGetFormatDescription(sample), makeSession(format) {
                        isUsable = true
                    }
                    if !isUsable, let makeDecodingReader {
                        isDecodedByReader = true
                        // A reader that cannot be made is a scan failure (recorded by the maker): no more frames.
                        guard let reader = try? makeDecodingReader() else { return nil }
                        decodingReader = reader
                        readerToken = AssetReaderCensusToken(purpose: purpose, path: path, priority: .background)
                        continue
                    }
                }
                if !isDependedOn(sample) {
                    if !isNeeded(ms) {
                        if !isEvent {
                            skippedCount += 1
                            continue
                        }
                        eventCount += 1
                    }
                }
                guard let format = CMSampleBufferGetFormatDescription(sample), makeSession(format), let session else { continue }
                switch session.decodeSynchronously(sample) {
                case let .success(buffer):
                    decodedCount += 1
                    return (buffer, ms, isEvent)
                case let .failure(failure):
                    if [-12913, -12911, -12903].contains(failure.status) {
                        session.invalidate()
                        self.session = nil
                    }
                }
            }
            return nil
        }

        func nextSample() -> CMSampleBuffer? {
            if let (reader, output) = decodingReader {
                while let sample = output.copyNextSampleBuffer() {
                    if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
                }
                if reader.status == .failed {
                    failure = reader.error?.localizedDescription ?? "unknown error"
                }
                return nil
            }
            guard let samples else { return nil }
            if let sample = samples.next() { return sample }
            if let f = samples.failure { failure = f }
            return nil
        }

        /// Whether a non-key frame is much larger than usual (more than 3× the median of the last 32
        /// non-key frames and over 6000 bytes): such frames usually carry a visible change.
        func noteSize(of sample: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool, notSync else { return false }
            let size = CMSampleBufferGetTotalSampleSize(sample)
            defer {
                recentSizes.append(size)
                if recentSizes.count > 32 { recentSizes.removeFirst() }
            }
            guard recentSizes.count >= 8 else { return false }
            let median = recentSizes.sorted()[recentSizes.count / 2]
            return max(median * 3, 6000) < size
        }

        func makeSession(_ format: CMFormatDescription) -> Bool {
            if let session {
                if session.canAccept(format) { return true }
                session.invalidate()
                self.session = nil
            }
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: UInt32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            session = try? DecoderSession(format: format, imageBufferAttributes: attributes, priority: .background, purpose: purpose, path: path)
            return session != nil
        }

        /// Whether other frames need this one to decode (true when unknown).
        func isDependedOn(_ sample: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first, let value = first[kCMSampleAttachmentKey_IsDependedOnByOthers] else { return true }
            return (value as? Bool) ?? true
        }
    }
}
