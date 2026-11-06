import Accelerate
import AVFoundation
import CoreVideo
import Foundation

enum MatteChunkError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Mattes stored as an H.264 movie: each matte is the luma of a video-range 4:2:0 frame
/// (0…255 → 16…235), chroma flat at 128, one frame per matte at `framesPerSecond`.
enum MatteChunkWriter {
    /// `videoRangeLuma[v]`: the luma byte a matte value is stored as.
    static let videoRangeLuma: [UInt8] = (0..<256).map { UInt8(Int(Double($0) * 219 / 255 + 16)) }

    /// Writes beside `url` first and moves the finished, synced file there.
    static func write(mattes: [[UInt8]], width: Int, height: Int, framesPerSecond: Int, to url: URL, encoderSpecification: [String: Any]? = nil) throws {
        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".writing-" + UUID().uuidString + "-" + url.lastPathComponent)
        defer { try? fileManager.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(width * height * framesPerSecond)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: mattes.count < 2 ? 1 : mattes.count,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            ] as [String: Any],
        ]
        if let encoderSpecification { settings[AVVideoEncoderSpecificationKey] = encoderSpecification }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw MatteChunkError.message("cannot add the video input") }
        writer.add(input)
        guard writer.startWriting() else { throw MatteChunkError.message(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
        let timescale = CMTimeScale(framesPerSecond)
        for (index, matte) in mattes.enumerated() {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw MatteChunkError.message(writer.error?.localizedDescription ?? "") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            let frame = try makeLumaFrame(matte, width: width, height: height)
            guard adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: timescale)) else {
                throw MatteChunkError.message(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(mattes.count), timescale: timescale))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw MatteChunkError.message(writer.error?.localizedDescription ?? "status " + String(writer.status.rawValue))
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    static func makeLumaFrame(_ matte: [UInt8], width: Int, height: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        guard let buffer = created else { throw MatteChunkError.message("Cannot create a luma frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw MatteChunkError.message("Cannot create a luma frame")
        }
        var matte = matte
        matte.withUnsafeMutableBytes { bytes in
            var source = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            var target = vImage_Buffer(data: luma, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
            videoRangeLuma.withUnsafeBufferPointer { table in
                _ = vImageTableLookUp_Planar8(&source, &target, table.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        memset(chroma, 0x80, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }
}

/// Reads back what `MatteChunkWriter` stored: each frame's luma, 16…235 → 0…255.
enum MatteChunkReader {
    /// `fullRange[y]`: the matte value of a stored luma byte.
    static let fullRange: [UInt8] = (0..<256).map { UInt8(min(max(Double(Int((Double($0) - 16) * 255 / 219)), 0), 255)) }

    static func read(_ url: URL, width: Int, height: Int) throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url, options: nil)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw MatteChunkError.message("no track in " + url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MatteChunkError.message(reader.error?.localizedDescription ?? url.lastPathComponent)
        }
        var mattes: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            var matte = [UInt8](repeating: 0, count: width * height)
            if let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0) {
                var source = vImage_Buffer(data: luma, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                           rowBytes: CVPixelBufferGetBytesPerRowOfPlane(frame, 0))
                matte.withUnsafeMutableBytes { bytes in
                    var target = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    fullRange.withUnsafeBufferPointer { table in
                        _ = vImageTableLookUp_Planar8(&source, &target, table.baseAddress!, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
            mattes.append(matte)
        }
        if let error = reader.error { throw MatteChunkError.message(error.localizedDescription) }
        return mattes
    }
}
