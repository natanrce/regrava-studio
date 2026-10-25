@preconcurrency import AVFoundation
import CoreImage
import Foundation
import RegravaCore
@preconcurrency import Vision

/// Finds sensitive text and faces in a recording: frames are sampled every 50 ms in chunks on the
/// grid; 32 px tiles whose look changed are read once they settle (120 ms still, 400 ms after
/// their last read) or after 300 ms; a fast Vision read picks candidate lines, which are read
/// again accurately (small text enlarged 2–3×), and `SensitiveText` turns them into spans. Faces
/// are proposed by the pico cascade and confirmed by Vision on a 3× crop.
///
/// Simplifications: no scroll measurement or motion walk, no EdgeRefiner (edges are
/// sample-exact, 50 ms), faces are searched again on each change instead of
/// template-followed, and evidence is not cached per chunk (a scan with other phrases starts over).
public enum SensitiveDataScanner {
    public struct Options: Sendable {
        public var sampleMs = 50.0
        public var settleMs = 120.0
        public var maxDirtyMs = 300.0
        public var minRereadMs = 400.0
        public var changeThreshold = 20
        public var enlargesSmallText = true
        public init() {}
    }

    /// The chunk boundaries (`ChunkGrid.forVideo`): 4/4/8/8 s leads then 24 s.
    public static func chunkBoundaries(durationMs: Double, lanes: Int = 1) -> [Double] {
        let per = Double(Int(durationMs / Double(max(lanes, 1)) / 2000) * 2000)
        let size: Double
        var leads: [Double] = []
        if per < 4000 { size = 4000 } else if per < 24000 { size = per } else { size = 24000; leads = [4000, 4000, 8000, 8000] }
        var bounds: [Double] = [0]
        for lead in leads where bounds.last! + lead < durationMs { bounds.append(bounds.last! + lead) }
        while bounds.last! + size < durationMs { bounds.append(bounds.last! + size) }
        bounds.append(max(durationMs, 1))
        return bounds
    }

    /// Scans the whole recording; `progress` gets the detections so far and the time up to which
    /// they are final.
    public static func scan(video: URL, phrases: [String], detectFaces: Bool, options: Options = Options(),
                            progress: @Sendable ([SensitiveDataDetection], Double) -> Void) async throws -> [SensitiveDataDetection] {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let durationMs = try await asset.load(.duration).seconds * 1000
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        let state = ScanState(options: options, phrases: phrases, detectFaces: detectFaces)
        let bounds = chunkBoundaries(durationMs: durationMs)
        var nextBound = 1
        var lastSample = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
            guard t - lastSample >= options.sampleMs, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            lastSample = t
            state.process(buffer, atMs: t)
            if nextBound < bounds.count, t >= bounds[nextBound] {
                // A chunk is done: read what is still dirty (`isForced`).
                state.flush(buffer, atMs: t)
                nextBound += 1
                progress(state.detections(endMs: t, isFinal: false), max(0, t - 1000))
            }
        }
        state.finish(atMs: durationMs)
        let detections = state.detections(endMs: durationMs, isFinal: true)
        progress(detections, durationMs)
        return detections
    }
}

/// One read item followed over time (`Tracker`, simplified).
private struct TrackedItem {
    var kind: SensitiveDataKind
    var text: String
    var key: String
    var startMs: Double
    var endMs: Double?
    var keyframes: [SensitiveDataKeyframe]
    var lastSeenMs: Double
    var rect: CGRect
}

private final class ScanState: @unchecked Sendable {
    let options: SensitiveDataScanner.Options
    let phrases: [String]
    let detectFaces: Bool
    private var width = 0, height = 0, columns = 0, rows = 0
    private var signatures: [UInt8] = []
    private var dirtySince: [Double] = []
    private var lastChange: [Double] = []
    private var lastRead: [Double] = []
    private var items: [TrackedItem] = []
    private var faces: [TrackedItem] = []
    private let cascade = PicoCascade.bundled

    init(options: SensitiveDataScanner.Options, phrases: [String], detectFaces: Bool) {
        self.options = options
        self.phrases = phrases
        self.detectFaces = detectFaces
    }

    // MARK: Change detection

    /// 16 block means (8×8 px) per 32 px tile of the luma plane.
    private func computeSignatures(_ luma: UnsafePointer<UInt8>, rowBytes: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: columns * rows * 16)
        for tileRow in 0..<rows {
            for tileCol in 0..<columns {
                for by in 0..<4 {
                    for bx in 0..<4 {
                        let x0 = tileCol * 32 + bx * 8, y0 = tileRow * 32 + by * 8
                        guard x0 < width, y0 < height else { continue }
                        var sum = 0, n = 0
                        for y in stride(from: y0, to: min(y0 + 8, height), by: 2) {
                            let row = luma + y * rowBytes
                            for x in stride(from: x0, to: min(x0 + 8, width), by: 2) { sum += Int(row[x]); n += 1 }
                        }
                        out[(tileRow * columns + tileCol) * 16 + by * 4 + bx] = UInt8(sum / max(n, 1))
                    }
                }
            }
        }
        return out
    }

    /// Two looks differ when a block moved more than the threshold once the tile's mean shift is
    /// removed (brightness changes and codec noise do not count).
    private func differs(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
        var diffs = [Int](repeating: 0, count: 16)
        var mean = 0
        for i in 0..<16 {
            diffs[i] = Int(a[a.startIndex + i]) - Int(b[b.startIndex + i])
            mean += diffs[i]
        }
        mean /= 16
        return diffs.contains { abs($0 - mean) > options.changeThreshold }
    }

    func process(_ buffer: CVPixelBuffer, atMs t: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        if width == 0 {
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            columns = (width + 31) >> 5
            rows = (height + 31) >> 5
            dirtySince = [Double](repeating: t, count: columns * rows)
            lastChange = [Double](repeating: t, count: rows)
            lastRead = [Double](repeating: -.infinity, count: rows)
            signatures = computeSignatures(luma, rowBytes: rowBytes)
        } else {
            let current = computeSignatures(luma, rowBytes: rowBytes)
            for tile in 0..<(columns * rows) {
                let range = (tile * 16)..<(tile * 16 + 16)
                if differs(current[range], signatures[range]) {
                    if dirtySince[tile] < 0 { dirtySince[tile] = t }
                    lastChange[tile / columns] = t
                    endItems(touching: tile, atMs: t)
                }
            }
            signatures = current
        }
        readDueTiles(buffer, atMs: t, isForced: false)
    }

    func flush(_ buffer: CVPixelBuffer, atMs t: Double) { readDueTiles(buffer, atMs: t, isForced: true) }

    func finish(atMs t: Double) {
        for i in items.indices where items[i].endMs == nil { items[i].endMs = t }
        for i in faces.indices where faces[i].endMs == nil { faces[i].endMs = t }
    }

    /// A covered item whose pixels changed ends there unless a read finds it again.
    private func endItems(touching tile: Int, atMs t: Double) {
        let rect = CGRect(x: (tile % columns) * 32, y: (tile / columns) * 32, width: 32, height: 32)
        for i in items.indices where items[i].endMs == nil && items[i].rect.intersects(rect) {
            items[i].endMs = t
        }
    }

    // MARK: Reads

    private func readDueTiles(_ buffer: CVPixelBuffer, atMs t: Double, isForced: Bool) {
        var dueRows = Set<Int>()
        for tile in 0..<(columns * rows) where dirtySince[tile] >= 0 {
            let row = tile / columns
            let settled = t - lastChange[row] >= options.settleMs && t - lastRead[row] >= options.minRereadMs
            let stale = t - dirtySince[tile] >= options.maxDirtyMs
            if isForced || settled || stale { dueRows.insert(row) }
        }
        guard !dueRows.isEmpty else { return }
        for band in readingBands(dueRows.sorted()) {
            for row in band {
                lastRead[row] = t
                for col in 0..<columns { dirtySince[row * columns + col] = -1 }
            }
            let y0 = band.lowerBound * 32, y1 = min(band.upperBound * 32 + 32, height)
            read(buffer, band: CGRect(x: 0, y: y0, width: width, height: y1 - y0), atMs: t)
        }
    }

    /// Adjacent due rows join; more than 45 % of the height reads the whole frame (`readingBands`).
    private func readingBands(_ due: [Int]) -> [ClosedRange<Int>] {
        if Double(due.count) > Double(rows) * 0.45 { return [0...(rows - 1)] }
        var bands: [ClosedRange<Int>] = []
        for row in due {
            if let last = bands.last, last.upperBound + 1 >= row { bands[bands.count - 1] = last.lowerBound...row } else { bands.append(row...row) }
        }
        return bands
    }

    private func image(_ buffer: CVPixelBuffer, rect: CGRect, scale: CGFloat = 1) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        // Top-left pixel rect → Core Image's bottom-left space.
        let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
        var cropped = ci.cropped(to: flipped).transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        if scale != 1 { cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return ScanState.context.createCGImage(cropped, from: cropped.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Lines of a crop, in video pixels (top-left origin).
    private func recognize(_ cg: CGImage, level: VNRequestTextRecognitionLevel, origin: CGPoint, scale: CGFloat) -> [(text: String, rect: CGRect, observation: VNRecognizedText, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        return (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            let rect = CGRect(x: origin.x + b.minX * w / scale, y: origin.y + (1 - b.maxY) * h / scale, width: b.width * w / scale, height: b.height * h / scale)
            return (top.string, rect, top, b)
        }
    }

    /// `readText`: fast read, accurate re-read of candidate lines, small text enlarged.
    private func read(_ buffer: CVPixelBuffer, band: CGRect, atMs t: Double) {
        guard let crop = image(buffer, rect: band) else { return }
        var lines = recognize(crop, level: .fast, origin: band.origin, scale: 1)
        // Candidates: a long token, or a zip code in short text (`isSensitiveCandidate`).
        let long = try? NSRegularExpression(pattern: "[A-Za-z0-9_\\-]{14,}")
        let zip = try? NSRegularExpression(pattern: "\\b\\d{5}\\b")
        func isCandidate(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            if text.count >= 7 {
                return long?.firstMatch(in: text, range: range) != nil || text.contains("@") || text.filter(\.isNumber).count >= 6
                    || !SensitiveText.spans(inLine: text).isEmpty
            }
            return zip?.firstMatch(in: text, range: range) != nil
        }
        var accurate: [(text: String, rect: CGRect, observation: VNRecognizedText, box: CGRect)] = []
        for line in lines where isCandidate(line.text) {
            // The line's rows padded by 0.6 × its height (`candidateRows`). Vision's accurate level
            // reads nothing in a frame-wide strip a few dozen pixels tall, so the crop also stays
            // around the line horizontally (a Regrava adaptation).
            let pad = line.rect.height * 0.6
            let x0 = max(line.rect.minX - line.rect.height * 4, 0), x1 = min(line.rect.maxX + line.rect.height * 4, CGFloat(width))
            let rows = CGRect(x: x0, y: max(line.rect.minY - pad, 0), width: x1 - x0, height: min(line.rect.height + 2 * pad, CGFloat(height) - max(line.rect.minY - pad, 0)))
            if let cg = image(buffer, rect: rows) { accurate += recognize(cg, level: .accurate, origin: rows.origin, scale: 1) }
        }
        if !accurate.isEmpty {
            lines.removeAll { line in accurate.contains { $0.rect.intersects(line.rect) } }
            lines += accurate
        }
        // Text under 15 px read again enlarged to about 30 px (2–3×).
        // Only fast lines: what was read accurately stays (`readText` enlarges the fast read's small lines).
        let isAccurate = { (line: (text: String, rect: CGRect, observation: VNRecognizedText, box: CGRect)) in accurate.contains { $0.rect == line.rect && $0.text == line.text } }
        if options.enlargesSmallText, let minH = lines.filter({ !isAccurate($0) }).map(\.rect.height).filter({ $0 < 15 }).min() {
            let scale = min(minH < 1 ? 30 : max(30 / minH, 2), 3)
            let small = lines.filter { $0.rect.height < 15 && !isAccurate($0) }
            let top = small.map(\.rect.minY).min()!, bottom = small.map(\.rect.maxY).max()!
            let rows = CGRect(x: 0, y: max(top - 4, 0), width: CGFloat(width), height: min(bottom - top + 8, CGFloat(height) - max(top - 4, 0)))
            if let cg = image(buffer, rect: rows, scale: scale) {
                let enlarged = recognize(cg, level: .fast, origin: rows.origin, scale: scale)
                    .filter { new in !accurate.contains { $0.rect.intersects(new.rect) } }
                lines.removeAll { $0.rect.height < 15 && !isAccurate($0) }
                lines += enlarged
            }
        }
        lines.sort { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        let textLines = lines.map { SensitiveTextLine(text: $0.text, rect: $0.rect) }
        for span in SensitiveText.spans(in: textLines, customPhrases: phrases) {
            let line = lines[span.line]
            guard let range = Range(span.range, in: line.text), let box = try? line.observation.boundingBox(for: range) else { continue }
            let b = box.boundingBox
            // Back from the crop's normalized space through the line's rect.
            let crop = line.rect
            let lineBox = line.box
            let rx = (b.minX - lineBox.minX) / max(lineBox.width, 0.0001), rw = b.width / max(lineBox.width, 0.0001)
            let rect = CGRect(x: crop.minX + rx * crop.width, y: crop.minY, width: rw * crop.width, height: crop.height).integral
            let text = (line.text as NSString).substring(with: span.range)
            track(kind: span.kind, text: text, rect: rect, atMs: t)
        }
        if detectFaces { searchFaces(buffer, band: band, atMs: t) }
    }

    // MARK: Tracking (simplified)

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { !$0.isWhitespace } }

    private func track(kind: SensitiveDataKind, text: String, rect: CGRect, atMs t: Double) {
        let key = Self.fold(text)
        if let i = items.lastIndex(where: { $0.key == key && $0.kind == kind && ($0.endMs == nil || t - ($0.endMs ?? t) <= options.minRereadMs) && iou($0.rect, rect) >= 0.2 }) {
            // The same item read again: it goes on (and moves with a new keyframe).
            items[i].endMs = nil
            items[i].lastSeenMs = t
            if iou(items[i].rect, rect) < 0.9 {
                items[i].keyframes.append(SensitiveDataKeyframe(timeMs: t, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
                items[i].rect = rect
            }
            return
        }
        // A new item starts when the tiles under it last changed (`startMs(of:foundAt:)`).
        let firstRow = max(Int(rect.minY) >> 5, 0), lastRow = min(Int(rect.maxY) >> 5, rows - 1)
        let start = firstRow <= lastRow ? (firstRow...lastRow).map { lastChange[$0] }.max() ?? t : t
        items.append(TrackedItem(kind: kind, text: text, key: key, startMs: min(start, t), endMs: nil,
                                 keyframes: [SensitiveDataKeyframe(timeMs: min(start, t), x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)],
                                 lastSeenMs: t, rect: rect))
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        return Double(i / (a.width * a.height + b.width * b.height - i))
    }

    // MARK: Faces

    private func searchFaces(_ buffer: CVPixelBuffer, band: CGRect, atMs t: Double) {
        guard let cascade, let cg = image(buffer, rect: band) else { return }
        let w = cg.width, h = cg.height
        guard w >= 10, h >= 10 else { return }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Smallest face: a 24th of the area's short side, or 20 px under 480 (`searchFaces`).
        let shortSide = min(w, h)
        let minSize = shortSide < 480 ? 20 : shortSide / 24
        let proposals = cascade.detect(gray: gray, width: w, height: h, parameters: .init(minSize: max(minSize, 10), maxSize: shortSide, shiftFactor: 0.1, scaleFactor: 1.1, overlapThreshold: 0.2))
        var found: [CGRect] = []
        for proposal in proposals.sorted(by: { $0.score > $1.score }).prefix(16) {
            // Vision on a 3× square around the proposal; kept at ≥ 0.6 of its size.
            let side = proposal.size * 3
            let crop = CGRect(x: proposal.x - side / 2, y: proposal.y - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !crop.isNull, let sub = cg.cropping(to: crop) else { continue }
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: sub).perform([request])
            for face in request.results ?? [] {
                let b = face.boundingBox
                let fw = b.width * crop.width, fh = b.height * crop.height
                guard max(fw, fh) >= 0.6 * proposal.size else { continue }
                let cx = crop.minX + b.midX * crop.width, cy = crop.minY + (1 - b.midY) * crop.height
                // The cover: a 1.25× square around the face.
                let s = max(fw, fh) * 1.25
                let rect = CGRect(x: band.minX + cx - s / 2, y: band.minY + cy - s / 2, width: s, height: s).integral
                if !found.contains(where: { iou($0, rect) > 0.3 }) { found.append(rect) }
            }
        }
        for rect in found {
            if let i = faces.lastIndex(where: { $0.endMs == nil && iou($0.rect, rect) > 0.2 && t - $0.lastSeenMs < 500 }) {
                faces[i].lastSeenMs = t
                if iou(faces[i].rect, rect) < 0.9 {
                    faces[i].keyframes.append(SensitiveDataKeyframe(timeMs: t, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
                    faces[i].rect = rect
                }
            } else {
                faces.append(TrackedItem(kind: .face, text: "", key: "", startMs: t, endMs: nil,
                                         keyframes: [SensitiveDataKeyframe(timeMs: t, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)],
                                         lastSeenMs: t, rect: rect))
            }
        }
        // A face not seen for 500 ms ends there (a gap ≥ 500 ms ends a track).
        for i in faces.indices where faces[i].endMs == nil && t - faces[i].lastSeenMs >= 500 && band.intersects(faces[i].rect) {
            faces[i].endMs = faces[i].lastSeenMs + options.sampleMs
        }
    }

    // MARK: Output (`SensitiveDataResolver.resolve`)

    func detections(endMs: Double, isFinal: Bool) -> [SensitiveDataDetection] {
        (items + faces).map { item in
            SensitiveDataDetection(kind: item.kind, text: item.text, startMs: (item.startMs * 1000).rounded() / 1000,
                                   endMs: ((item.endMs ?? endMs) * 1000).rounded() / 1000, keyframes: item.keyframes.map {
                                       SensitiveDataKeyframe(timeMs: $0.timeMs, x: $0.x.rounded(.down), y: $0.y.rounded(.down), width: $0.width.rounded(.down), height: $0.height.rounded(.down))
                                   })
        }
        .filter { $0.endMs > $0.startMs }
        .sorted { $0.startMs < $1.startMs }
    }
}
