import Accelerate
import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Vision

/// The person matte of one webcam frame inside its person window, `width`×`height` bytes in
/// rows from the top, by Apple Vision person segmentation at its accurate level. One matter
/// works on one frame at a time.
final class FrameMatter: @unchecked Sendable {
    static let width = MatteCache.matteWidth
    static let height = MatteCache.matteHeight
    /// Names the mattes in cache identities and window files.
    static let model = "vision-person-segmentation-accurate"

    let window: CGRect
    /// Whether the model ran on the blank frame at creation.
    private(set) var isLoaded = false
    /// The whole-frame matter for webcam frames that are not from a project's movie.
    static let wholeFrame = FrameMatter(window: PersonWindow.wholeFrame)
    private let request = VNGeneratePersonSegmentationRequest()
    private let lock = NSLock()
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// Loads the model by matting a blank frame, so the first real frame does not wait for it.
    init(window: CGRect) {
        self.window = window
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if let blank = Self.blankFrame() { isLoaded = (try? matte(blank)) != nil }
    }

    private static func blankFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer
    }

    /// The window of `frame` in Core Image coordinates (bottom-up).
    static func windowRect(_ window: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + window.minX * extent.width, y: extent.minY + (1 - window.minY - window.height) * extent.height,
               width: window.width * extent.width, height: window.height * extent.height)
    }

    func matte(_ frame: CVPixelBuffer) throws -> [UInt8] {
        try matte(CIImage(cvPixelBuffer: frame))
    }

    func matte(_ image: CIImage) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let rect = Self.windowRect(window, in: image.extent)
        let input = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        try VNImageRequestHandler(ciImage: input, options: [:]).perform([request])
        guard let mask = request.results?.first?.pixelBuffer else { throw MatteChunkError.message("The matte network returned no matte") }
        let maskImage = CIImage(cvPixelBuffer: mask)
        let scaled = maskImage.transformed(by: CGAffineTransform(scaleX: CGFloat(Self.width) / maskImage.extent.width, y: CGFloat(Self.height) / maskImage.extent.height))
        var out = [UInt8](repeating: 0, count: Self.width * Self.height)
        out.withUnsafeMutableBytes { bytes in
            Self.context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: Self.width, bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), format: .L8, colorSpace: nil)
        }
        return out
    }

    private static let guideKernel = RenderKernels.general("cameraMatteGuide")

    /// The window of the footage at matte size, three planes (r, g, b), each pixel the mean of a
    /// box of up to 4×4 bilinear reads, stored as half floats in −1…1 and brought to 0…255.
    static func guide(_ frame: CVPixelBuffer, window: CGRect) -> [UInt8] {
        let count = width * height
        var guide = [UInt8](repeating: 0, count: count * 3)
        guard let guideKernel else { return guide }
        let image = CIImage(cvPixelBuffer: frame)
        let extent = image.extent
        let rect = windowRect(window, in: extent)
        let taps = CIVector(x: CGFloat(taps(window.width * extent.width / Double(width))), y: CGFloat(taps(window.height * extent.height / Double(height))))
        let output = CGRect(x: 0, y: 0, width: width, height: height)
        guard let sampled = guideKernel.apply(extent: output, roiCallback: { _, _ in rect.insetBy(dx: -2, dy: -2) },
                                              arguments: [image.clampedToExtent(), CIVector(cgRect: rect), CIVector(x: CGFloat(width), y: CGFloat(height)), taps]) else { return guide }
        var rgba = [Float](repeating: 0, count: count * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(sampled, toBitmap: bytes.baseAddress!, rowBytes: width * 16, bounds: output, format: .RGBAf, colorSpace: nil)
        }
        // Planes, normalized to −1…1 and rounded through half floats like the network's input.
        var planes = [Float](repeating: 0, count: count * 4)
        var halves = [UInt16](repeating: 0, count: count * 3)
        rgba.withUnsafeMutableBytes { interleaved in
            planes.withUnsafeMutableBytes { planar in
                let base = planar.baseAddress!
                var source = vImage_Buffer(data: interleaved.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
                var r = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var g = vImage_Buffer(data: base + count * 4, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var b = vImage_Buffer(data: base + count * 8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var a = vImage_Buffer(data: base + count * 12, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                // Channel order is kept: r, g, b, a.
                _ = vImageConvert_ARGBFFFFtoPlanarF(&source, &r, &g, &b, &a, vImage_Flags(kvImageNoFlags))
                let values = base.assumingMemoryBound(to: Float.self)
                var scale: Float = 2, offset: Float = -1
                vDSP_vsmsa(values, 1, &scale, &offset, values, 1, vDSP_Length(count * 3))
                halves.withUnsafeMutableBytes { half in
                    var floats = vImage_Buffer(data: base, height: vImagePixelCount(height * 3), width: vImagePixelCount(width), rowBytes: width * 4)
                    var packed = vImage_Buffer(data: half.baseAddress, height: vImagePixelCount(height * 3), width: vImagePixelCount(width), rowBytes: width * 2)
                    _ = vImageConvert_PlanarFtoPlanar16F(&floats, &packed, vImage_Flags(kvImageNoFlags))
                    _ = vImageConvert_Planar16FtoPlanarF(&packed, &floats, vImage_Flags(kvImageNoFlags))
                }
                guide.withUnsafeMutableBytes { target in
                    var floats = vImage_Buffer(data: base, height: vImagePixelCount(height * 3), width: vImagePixelCount(width), rowBytes: width * 4)
                    var bytes = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(height * 3), width: vImagePixelCount(width), rowBytes: width)
                    _ = vImageConvert_PlanarFtoPlanar8(&floats, &bytes, 1, -1, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        return guide
    }

    /// Reads per output pixel along one axis: source pixels per matte pixel, rounded, 1…4.
    static func taps(_ sourcePerMatte: Double) -> Int {
        guard sourcePerMatte > 0 else { return 1 }
        let rounded = Int(sourcePerMatte.rounded(.toNearestOrAwayFromZero))
        return rounded < 1 ? 1 : min(rounded, 4)
    }
}

/// Where the person is in a webcam video: the box around the matte of eight frames spread over
/// it, grown by a fifth, snapped out to a 0.05 grid, or the whole frame when that covers more
/// than three quarters of it (or no person shows). Kept as `window-<hash>.json` in the cache root.
enum PersonWindow {
    static let wholeFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    struct StoredWindow: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    static func window(videoURL: URL, frameTimes: [CMTime], model: String, cacheRoot: URL) throws -> CGRect {
        let key = String(1) + "|" + MatteCache.videoKey(forVideoAt: videoURL.path) + "|" + model
        let file = cacheRoot.appendingPathComponent("window-" + MatteCache.shortHash(key) + ".json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(StoredWindow.self, from: data) {
            return CGRect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
        }
        let matter = FrameMatter(window: wholeFrame)
        let window = try estimate(videoURL: videoURL, frameTimes: frameTimes, matter: matter)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true, attributes: nil)
        let stored = StoredWindow(x: window.minX, y: window.minY, width: window.width, height: window.height)
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        return window
    }

    static func estimate(videoURL: URL, frameTimes: [CMTime], matter: FrameMatter) throws -> CGRect {
        guard let first = frameTimes.first, let last = frameTimes.last else { return wholeFrame }
        let duration = (last - first).seconds
        var union: CGRect?
        for sample in 0..<8 {
            let target = duration * (Double(sample) + 0.5) * 0.125 + first.seconds
            let index = frameTimes.lastIndex { $0.seconds <= target } ?? 0
            guard let frame = try CameraFrames.decodeFrame(videoURL: videoURL, at: frameTimes[index]) else { continue }
            if let box = personBox(try matter.matte(frame)) {
                union = union.map { $0.union(box) } ?? box
            }
        }
        guard let union else { return wholeFrame }
        let window = quantize(expand(union, by: 0.2))
        return window.width * window.height > 0.75 ? wholeFrame : window
    }

    /// The box (0…1, from the top) around matte values of 128 and more.
    static func personBox(_ matte: [UInt8]) -> CGRect? {
        let width = FrameMatter.width, height = FrameMatter.height
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where matte[y * width + x] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                      width: Double(maxX + 1 - minX) / Double(width), height: Double(maxY + 1 - minY) / Double(height))
    }

    static func expand(_ rect: CGRect, by amount: Double) -> CGRect {
        let x0 = rect.minX - amount * rect.width, y0 = rect.minY - amount * rect.height
        let minX = x0 >= 0 ? x0 : 0, minY = y0 >= 0 ? y0 : 0
        let maxX = min(rect.maxX + amount * rect.width, 1), maxY = min(rect.maxY + amount * rect.height, 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func quantize(_ rect: CGRect) -> CGRect {
        let step = 0.05
        let minX = (rect.minX / step).rounded(.down) * step, minY = (rect.minY / step).rounded(.down) * step
        let maxX = min((rect.maxX / step).rounded(.up) * step, 1), maxY = min((rect.maxY / step).rounded(.up) * step, 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Webcam frames for the matte: presentation times and BGRA decodes.
enum CameraFrames {
    static let decodedAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// Every shown frame's presentation time, ascending: sample times through the track's
    /// edits, the frame showing when an edit starts at its start.
    static func frameTimes(videoURL: URL) throws -> [CMTime] {
        let asset = AVURLAsset(url: videoURL, options: nil)
        guard let track = asset.tracks(withMediaType: .video).first else { throw MatteChunkError.message("Cannot read the video: " + videoURL.path) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw MatteChunkError.message("Cannot read the video: " + (reader.error?.localizedDescription ?? "")) }
        var samples: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            if CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == 0 {
                samples.append(contentsOf: timing.map(\.presentationTimeStamp))
            } else {
                samples.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        if let error = reader.error { throw MatteChunkError.message("Cannot read the video: " + error.localizedDescription) }
        samples.sort { $0 < $1 }
        let edits = track.segments.filter { !$0.isEmpty }.map(\.timeMapping)
        guard !edits.isEmpty else { return samples }
        var shown: [CMTime] = []
        for edit in edits {
            let inside = samples.filter { edit.source.containsTime($0) }
            if inside.first != edit.source.start, samples.contains(where: { $0 < edit.source.start }) {
                shown.append(edit.target.start)
            }
            shown.append(contentsOf: inside.map { CMTimeMapTimeFromRangeToRange($0, fromRange: edit.source, toRange: edit.target) })
        }
        var unique: [CMTime] = []
        for time in shown.sorted(by: { $0 < $1 }) where unique.last != time { unique.append(time) }
        return unique
    }

    /// The frame shown at `time`.
    static func decodeFrame(videoURL: URL, at time: CMTime) throws -> CVPixelBuffer? {
        let reader = try DecodedFrames(videoURL: videoURL, from: time, to: nil)
        defer { reader.cancel() }
        while let (buffer, pts) = try reader.next() {
            if pts >= time { return buffer }
        }
        return nil
    }

    /// Decoded frames from `start` up to (not including) `end` (the video's end when nil), in
    /// presentation order.
    final class DecodedFrames {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput

        init(videoURL: URL, from start: CMTime, to end: CMTime?) throws {
            let asset = AVURLAsset(url: videoURL, options: nil)
            guard let track = asset.tracks(withMediaType: .video).first else { throw MatteChunkError.message("Cannot read the video: " + videoURL.path) }
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: max(start, .zero), end: end ?? .positiveInfinity)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: CameraFrames.decodedAttributes)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw MatteChunkError.message("Cannot read the video: " + (reader.error?.localizedDescription ?? "")) }
        }

        func next() throws -> (CVPixelBuffer, CMTime)? {
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                return (buffer, CMSampleBufferGetPresentationTimeStamp(sample))
            }
            if let error = reader.error { throw MatteChunkError.message("Cannot read the video: " + error.localizedDescription) }
            return nil
        }

        func cancel() {
            if reader.status == .reading { reader.cancelReading() }
        }
    }
}
