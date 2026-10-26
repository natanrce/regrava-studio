@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

// Video file access, compressed sample reading and VideoToolbox decoding used by the chunk scan.

extension SD {
    enum MediaError: Error {
        case noVideoTrack(path: String)
        case readerFailed(String)
    }

    /// How urgently a decoder is needed.
    enum DecodePriority {
        case interactive
        case background
    }

    /// Registry of open decoders and asset readers (diagnostics only).
    final class DecoderCensus {
        enum Kind { case videoToolbox, assetReader }

        final class Entry {
            let id: Int
            let purpose: String
            let path: String
            let kind: Kind
            let priority: DecodePriority
            let codec: String?
            let widthPx: Int
            let heightPx: Int
            let isHardwareAccelerated: Bool?
            let openedAt = Date()
            let lock = NSLock()
            var decodedCount = 0
            var failureCount = 0
            var lastFailureStatus: Int32?

            init(id: Int, purpose: String, path: String, kind: Kind, priority: DecodePriority, codec: String?, widthPx: Int, heightPx: Int,
                 isHardwareAccelerated: Bool?) {
                self.id = id
                self.purpose = purpose
                self.path = path
                self.kind = kind
                self.priority = priority
                self.codec = codec
                self.widthPx = widthPx
                self.heightPx = heightPx
                self.isHardwareAccelerated = isHardwareAccelerated
            }
        }

        nonisolated(unsafe) static let shared = DecoderCensus()
        let lock = NSLock()
        var entries: [Int: Entry] = [:]
        var nextId = 0

        func open(purpose: String, path: String, kind: Kind, priority: DecodePriority, codec: String?, widthPx: Int, heightPx: Int,
                  isHardwareAccelerated: Bool?) -> Entry {
            lock.lock()
            defer { lock.unlock() }
            let entry = Entry(id: nextId, purpose: purpose, path: path, kind: kind, priority: priority, codec: codec, widthPx: widthPx,
                              heightPx: heightPx, isHardwareAccelerated: isHardwareAccelerated)
            nextId += 1
            entries[entry.id] = entry
            return entry
        }

        func close(_ entry: Entry) {
            lock.lock()
            entries[entry.id] = nil
            lock.unlock()
        }
    }

    /// Keeps an asset reader listed in the census while it lives.
    final class AssetReaderCensusToken {
        let entry: DecoderCensus.Entry

        init(purpose: String, path: String, priority: DecodePriority) {
            entry = DecoderCensus.shared.open(purpose: purpose, path: path, kind: .assetReader, priority: priority, codec: nil, widthPx: 0,
                                              heightPx: 0, isHardwareAccelerated: nil)
        }

        deinit { DecoderCensus.shared.close(entry) }
    }

    /// A video file on disk.
    final class VideoFile {
        let url: URL
        let sharedAsset: AVURLAsset?

        init(url: URL) throws {
            self.url = url
            if url.pathExtension.lowercased() == "m3u8" {
                // HLS playlists (fragmented MP4 segments) are not supported by this part.
                throw MediaError.readerFailed("HLS playlists are not supported: " + url.path)
            }
            sharedAsset = AVURLAsset(url: url, options: nil)
        }

        var isPlaylist: Bool { false }

        func makeAsset() -> AVURLAsset { sharedAsset! }

        /// Compressed samples of the first video track between two times.
        func makeSampleReader(fromMs: Double, toMs: Double) throws -> VideoSampleReader {
            let asset = makeAsset()
            guard let track = asset.tracks(withMediaType: .video).first else { throw MediaError.noVideoTrack(path: url.path) }
            let source = try AVAssetReaderSource(asset: asset, track: track, fromMs: fromMs, toMs: toMs)
            return VideoSampleReader(source: source, endMs: toMs)
        }
    }

    /// The presentation edits (time mappings) of a track's non-empty segments.
    static func presentationEdits(of track: AVAssetTrack) -> [CMTimeMapping] {
        track.segments.filter { !$0.isEmpty }.map(\.timeMapping)
    }

    /// Where a media time shows on the timeline, through the edit whose source contains it.
    static func presentationTime(of time: CMTime, edits: [CMTimeMapping]) -> CMTime? {
        for edit in edits where edit.source.containsTime(time) {
            return CMTimeMapTimeFromRangeToRange(time, fromRange: edit.source, toRange: edit.target)
        }
        return nil
    }

    /// Asset reader of a movie track without decoding (compressed samples).
    final class AVAssetReaderSource {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let edits: [CMTimeMapping]

        init(asset: AVAsset, track: AVAssetTrack, fromMs: Double, toMs: Double) throws {
            edits = SD.presentationEdits(of: track)
            reader = try AVAssetReader(asset: asset)
            let start = CMTime(seconds: (fromMs >= 0 ? fromMs : 0) / 1000, preferredTimescale: 1000)
            let end = toMs.isFinite ? CMTime(seconds: toMs / 1000, preferredTimescale: 1000) : .positiveInfinity
            reader.timeRange = CMTimeRange(start: start, end: end)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? MediaError.readerFailed("Cannot start reading")
            }
        }

        var failure: String? {
            guard reader.status == .failed else { return nil }
            return reader.error?.localizedDescription ?? "unknown error"
        }

        /// The sample retimed to where it shows on the timeline.
        func showingTime(_ sample: CMSampleBuffer) -> CMSampleBuffer {
            guard let first = edits.first else { return sample }
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == 0 else { return sample }
            let pts = timing.presentationTimeStamp
            let shown = SD.presentationTime(of: pts, edits: edits)
                ?? CMTimeMapTimeFromRangeToRange(pts, fromRange: first.source, toRange: first.target)
            guard shown != pts else { return sample }
            let delta = shown - pts
            timing.presentationTimeStamp = shown
            if timing.decodeTimeStamp.isValid { timing.decodeTimeStamp = timing.decodeTimeStamp + delta }
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                               sampleTimingArray: &timing, sampleBufferOut: &copy)
            if status == 0, let copy { return copy }
            return sample
        }
    }

    /// Compressed video samples in decode order.
    final class VideoSampleReader {
        let source: AVAssetReaderSource
        let endMs: Double
        var isFinished = false
        var failure: String?

        init(source: AVAssetReaderSource, endMs: Double) {
            self.source = source
            self.endMs = endMs
        }

        func next() -> CMSampleBuffer? {
            if isFinished { return nil }
            while let sample = source.output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 { return source.showingTime(sample) }
            }
            failure = source.failure
            isFinished = true
            return nil
        }
    }

    struct DecodeFailure: Error {
        let status: Int32
    }

    enum DecoderSessionError: Error {
        case creationFailed(Int32)
        case cancelled
    }

    /// One VideoToolbox decompression session.
    final class DecoderSession {
        let session: VTDecompressionSession
        let isHardwareAccelerated: Bool
        let entry: DecoderCensus.Entry
        let lock = NSLock()
        var isInvalidated = false

        /// Asks for a hardware decoder for background work when the codec has one, waiting up to 10 s
        /// (0.25 s doubling to 2 s between tries) before settling for any decoder.
        init(format: CMFormatDescription, imageBufferAttributes: [String: Any], priority: DecodePriority, purpose: String, path: String,
             isCancelled: () -> Bool = { false }) throws {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let isHardwareSupported = VTIsHardwareDecodeSupported(codec)
            var waited = 0.0
            var delay = 0.25
            var created: VTDecompressionSession?
            while true {
                let mayFallBack = !isHardwareSupported || priority != .background || 10.0 <= waited
                let key = mayFallBack ? kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
                    : kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
                let specification = [key: true] as CFDictionary
                created = nil
                let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: specification,
                                                          imageBufferAttributes: imageBufferAttributes as CFDictionary,
                                                          outputCallback: nil, decompressionSessionOut: &created)
                if status == 0, created != nil { break }
                if mayFallBack { throw DecoderSessionError.creationFailed(status) }
                if isCancelled() { throw DecoderSessionError.cancelled }
                Thread.sleep(forTimeInterval: delay)
                waited += delay
                delay = min(delay + delay, 2)
            }
            session = created!
            var value: CFTypeRef?
            let hw: Bool
            if VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil,
                                     valueOut: &value) == 0, let b = value as? Bool {
                hw = b
            } else {
                hw = false
            }
            isHardwareAccelerated = hw
            entry = DecoderCensus.shared.open(purpose: purpose, path: path, kind: .videoToolbox, priority: priority,
                                              codec: String(format: "%08x", codec), widthPx: Int(dimensions.width),
                                              heightPx: Int(dimensions.height), isHardwareAccelerated: hw)
            // The diagnostic log line written when decoding falls back to software is not reproduced.
        }

        func canAccept(_ format: CMFormatDescription) -> Bool {
            VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format)
        }

        func invalidate() {
            lock.lock()
            let was = isInvalidated
            isInvalidated = true
            lock.unlock()
            if !was {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
                DecoderCensus.shared.close(entry)
            }
        }

        /// Decodes one sample and waits for its frame.
        func decodeSynchronously(_ sample: CMSampleBuffer) -> Result<CVPixelBuffer, DecodeFailure> {
            final class DecodeOutcome { var value: Result<CVPixelBuffer, DecodeFailure> = .failure(DecodeFailure(status: -12909)) }
            let outcome = DecodeOutcome()
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == 0, let image {
                    outcome.value = .success(image)
                } else {
                    outcome.value = .failure(DecodeFailure(status: status == 0 ? -12909 : status))
                }
            }
            if status != 0 { outcome.value = .failure(DecodeFailure(status: status)) }
            record(outcome.value)
            return outcome.value
        }

        private func record(_ result: Result<CVPixelBuffer, DecodeFailure>) {
            entry.lock.lock()
            switch result {
            case .success: entry.decodedCount += 1
            case let .failure(f):
                entry.failureCount += 1
                entry.lastFailureStatus = f.status
            }
            entry.lock.unlock()
        }

        deinit { invalidate() }
    }
}
