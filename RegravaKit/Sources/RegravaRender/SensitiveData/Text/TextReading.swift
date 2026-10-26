import Accelerate
import CoreGraphics
import Foundation
import Vision

// Text reading: turns a gray crop of the video frame into recognized lines and findings.
//
// Pipeline of `readText(_:)`:
//   1. stretch local contrast of dimmed tiles, read the whole crop with the fast recognizer;
//   2. lines that hold something sensitive (or look like they could) are read again with the
//      accurate recognizer on a band of rows around them;
//   3. when enabled, rows of small text (< 15 px) are enlarged up to 3× and read the same way.
// Findings are snapped to the ink of their glyphs. Coordinates are video pixels, top-left origin.

extension SD {
    /// One recognized line: the text object, its rect in the frame and the mapping of the
    /// recognizer's normalized rects (bottom-left origin) to frame rects.
    typealias ReadLine = (text: VNRecognizedText, rect: CGRect, toFrame: (CGRect) -> CGRect)

    /// What the accurate pass looks for.
    // Case names; the first case carries the fast pass's lines, the second a rule.
    enum TextMatching {
        /// Everything the classifier finds; the fast lines not read again stay as context.
        case sensitive(fastLines: [ReadLine])
        /// Only this rule (a custom phrase).
        case rule(PatternRule)
    }

    /// Time and pixels spent in accurate reads.
    final class AccurateTierStats {
        let lock: NSLock
        var seconds: Double
        var pixels: Int

        init(lock: NSLock = NSLock(), seconds: Double = 0, pixels: Int = 0) {
            self.lock = lock
            self.seconds = seconds
            self.pixels = pixels
        }
    }

    nonisolated(unsafe) static let accurateTierStats = AccurateTierStats()

    // MARK: Keys and matches

    /// The comparison key of a text: case, accents and width folded; o→0, l/i/|→1, s→5, b→8
    /// (the digits OCR confuses them with); everything that is not a letter or a number dropped.
    static func foldedKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [Character] = []
        for c in folded {
            if c == "o" {
                out.append("0")
            } else if c == "l" || c == "i" || c == "|" {
                out.append("1")
            } else if c == "s" {
                out.append("5")
            } else if c == "b" {
                out.append("8")
            } else if c.isLetter || c.isNumber {
                out.append(c)
            }
        }
        return String(out)
    }

    /// Spans → matches on `text`; spans whose range is not valid in `text` are dropped.
    static func patternMatches(_ spans: [TextSpan], in text: String) -> [PatternMatch] {
        var out: [PatternMatch] = []
        for span in spans {
            guard let range = Range(span.range, in: text) else { continue }
            out.append(PatternMatch(kind: span.kind, priority: span.priority, range: range))
        }
        return out
    }

    /// Accent/width folding used before matching, kept only when it does not change the line's
    /// UTF-16 or character count (so ranges map back to the text as read).
    static func matchingSubject(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        if folded.utf16.count == text.utf16.count && folded.count == text.count {
            return folded
        }
        return text
    }

    /// Classifier over a frame of lines: each line is matched folded (see `matchingSubject`),
    /// the multi-line rules run over the whole frame, results become ranges of the text as read.
    static func findSensitiveRanges(inFrame lines: [(text: String, rect: CGRect)]) -> [[PatternMatch]] {
        let frame = lines.map { SensitiveTextLine(text: matchingSubject($0.text), rect: $0.rect) }
        let spans = Classifier.frameSpans(frame)
        return zip(lines, spans).map { patternMatches($1, in: $0.text) }
    }

    /// `Foundation`'s `StringProtocol.contains(_:)` (an `NSString` search; empty never matches).
    static func foundationContains<A: StringProtocol, B: StringProtocol>(_ string: A, _ other: B) -> Bool {
        (String(string) as NSString).contains(String(other))
    }

    // MARK: Recognition

    /// Recognized lines of `image` (no language correction, no minimum text height), each with
    /// its frame rect and the mapping of normalized rects to the frame.
    static func recognizeText(_ image: GrayImage, level: VNRequestTextRecognitionLevel) -> [ReadLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let ox = image.originPx.x
        let oy = image.originPx.y
        let w = CGFloat(image.widthPx)
        let h = CGFloat(image.heightPx)
        let toFrame: (CGRect) -> CGRect = { r in
            CGRect(x: ox + r.minX * w, y: oy + (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        }
        var out: [ReadLine] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first else { continue }
            out.append((text: text, rect: toFrame(observation.boundingBox), toFrame: toFrame))
        }
        return out
    }

    // MARK: Gray images

    /// An 8-bit gray CGImage over `data` (rows of `width` bytes).
    static func grayCGImage(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Copies `rect` (whole pixels, truncated) of a luma plane into a gray image.
    static func makeGrayImage(luma: UnsafePointer<UInt8>, rowBytes: Int, rect: CGRect) -> GrayImage? {
        let x = Int(rect.minX)
        let y = Int(rect.minY)
        let w = Int(rect.width)
        let h = Int(rect.height)
        var data = Data(count: w * h)
        data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            guard let base = out.baseAddress else { return }
            for row in 0..<h {
                memcpy(base + row * w, luma + x + (y + row) * rowBytes, w)
            }
        }
        guard let cgImage = grayCGImage(data, width: w, height: h) else { return nil }
        return GrayImage(bytes: data, widthPx: w, heightPx: h, originPx: rect.origin, cgImage: cgImage)
    }
}

extension SD.GrayImage {
    /// Contrast stretched per 64×64 tile: each tile's 2nd and 98th percentiles (sampling every
    /// other pixel) map to black and white, the range never below 64, interpolated bilinearly
    /// between tile centres. With `isDimmedOnly`, tiles whose 98th percentile is 160 or brighter
    /// are left as they are.
    func withLocalContrast(isDimmedOnly: Bool) -> SD.GrayImage {
        let w = widthPx
        let h = heightPx
        let tile = 64
        let tilesX = (w + 63) / 64
        let tilesY = (h + 63) / 64
        var lows = [Float](repeating: 0, count: tilesX * tilesY)
        var ranges = [Float](repeating: 255, count: tilesX * tilesY)
        var out = Data(count: w * h)
        bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let px = src.bindMemory(to: UInt8.self)
            var hist = [Int](repeating: 0, count: 256)
            for ty in 0..<tilesY {
                let y1 = min((ty + 1) * 64, h)
                for tx in 0..<tilesX {
                    let x1 = min((tx + 1) * 64, w)
                    for i in 0..<256 { hist[i] = 0 }
                    var count = 0
                    for y in stride(from: ty * 64, to: y1, by: 2) {
                        for x in stride(from: tx * 64, to: x1, by: 2) {
                            hist[Int(px[y * w + x])] += 1
                            count += 1
                        }
                    }
                    var low = 255
                    var cum = 0
                    for v in 0..<256 {
                        cum += hist[v]
                        if count * 2 <= cum * 100 {
                            low = v
                            break
                        }
                    }
                    var high: Float?
                    cum = 0
                    for v in 0..<256 {
                        cum += hist[v]
                        if count * 98 <= cum * 100 {
                            high = Float(v)
                            if isDimmedOnly && v >= 160 { high = nil }
                            break
                        }
                    }
                    if high == nil {
                        if isDimmedOnly { continue }
                        high = 255
                    }
                    let i = ty * tilesX + tx
                    lows[i] = Float(low)
                    let r = high! - Float(low)
                    ranges[i] = 64 < r ? r : 64
                }
            }
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                Self.applyLocalContrast(into: dst, from: px, tilesX: tilesX, image: self, tilesY: tilesY, tile: tile,
                                        lows: lows, ranges: ranges)
            }
        }
        guard let cgImage = SD.grayCGImage(out, width: w, height: h) else { return self }
        return SD.GrayImage(bytes: out, widthPx: w, heightPx: h, originPx: originPx, cgImage: cgImage)
    }

    private static func applyLocalContrast(into dst: UnsafeMutableRawBufferPointer, from px: UnsafeBufferPointer<UInt8>,
                                           tilesX: Int, image: SD.GrayImage, tilesY: Int, tile: Int,
                                           lows: [Float], ranges: [Float]) {
        let out = dst.bindMemory(to: UInt8.self)
        var rowLows = [Float](repeating: 0, count: tilesX)
        var rowRanges = [Float](repeating: 0, count: tilesX)
        let maxTY = Float(tilesY - 1)
        let maxTX = Float(tilesX - 1)
        let lastTY = tilesY - 1
        let lastTX = tilesX - 1
        let t = Float(tile)
        for y in 0..<image.heightPx {
            let fy = (Float(y) + 0.5) / t - 0.5
            let cy = fy >= 0 ? (fy < maxTY ? fy : maxTY) : (maxTY > 0 ? 0 : maxTY)
            let y0 = Int(cy)
            let y1 = min(y0 + 1, lastTY)
            let v = cy - Float(y0)
            for i in 0..<tilesX {
                rowLows[i] = (1 - v) * lows[y0 * tilesX + i] + v * lows[y1 * tilesX + i]
                rowRanges[i] = (1 - v) * ranges[y0 * tilesX + i] + v * ranges[y1 * tilesX + i]
            }
            for x in 0..<image.widthPx {
                let fx = (Float(x) + 0.5) / t - 0.5
                let cx = fx >= 0 ? (fx < maxTX ? fx : maxTX) : (maxTX > 0 ? 0 : maxTX)
                let x0 = Int(cx)
                let x1 = min(x0 + 1, lastTX)
                let u = cx - Float(x0)
                let i = y * image.widthPx + x
                let low = (1 - u) * rowLows[x0] + u * rowLows[x1]
                let range = (1 - u) * rowRanges[x0] + u * rowRanges[x1]
                var value = ((Float(px[i]) - low) * 255) / range
                value = value >= 0 ? value : 0
                value = value < 255 ? value : 255
                out[i] = UInt8(value)
            }
        }
    }

    /// The part of the image inside `rect` (frame pixels, widened to whole pixels), or nil when
    /// that is narrower or shorter than 16 px.
    func cropped(to rect: CGRect) -> SD.GrayImage? {
        guard !rect.isNull else { return nil }
        let ox = originPx.x
        let oy = originPx.y
        let x0 = max(0, Int((rect.minX - ox).rounded(.down)))
        let x1 = min(Int((rect.maxX - ox).rounded(.up)), widthPx)
        let y0 = max(0, Int((rect.minY - oy).rounded(.down)))
        let y1 = min(Int((rect.maxY - oy).rounded(.up)), heightPx)
        let w = x1 - x0
        guard w >= 16 else { return nil }
        let h = y1 - y0
        guard h >= 16 else { return nil }
        var data = Data(count: w * h)
        let srcWidth = widthPx
        bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            data.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for y in y0..<y1 {
                    memcpy(d + (y - y0) * w, s + y * srcWidth + x0, w)
                }
            }
        }
        guard let cgImage = SD.grayCGImage(data, width: w, height: h) else { return nil }
        return SD.GrayImage(bytes: data, widthPx: w, heightPx: h, originPx: CGPoint(x: ox + CGFloat(x0), y: oy + CGFloat(y0)),
                            cgImage: cgImage)
    }

    /// The image scaled by `scale` (high-quality resampling, sizes rounded, at least 1 px).
    func resampled(by scale: CGFloat) -> SD.GrayImage {
        if scale == 1 { return self }
        let nw = max(1, Int((CGFloat(widthPx) * scale).rounded()))
        let nh = max(1, Int((CGFloat(heightPx) * scale).rounded()))
        var out = Data(count: nw * nh)
        bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: vImagePixelCount(heightPx),
                                      width: vImagePixelCount(widthPx), rowBytes: widthPx)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw)
                _ = vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard let cgImage = SD.grayCGImage(out, width: nw, height: nh) else { return self }
        return SD.GrayImage(bytes: out, widthPx: nw, heightPx: nh, originPx: CGPoint(x: scale * originPx.x, y: scale * originPx.y),
                            cgImage: cgImage)
    }

    /// Rows `from..<to` of the image (clamped), or nil when none are left.
    func rows(_ from: Int, _ to: Int) -> SD.GrayImage? {
        let lo = max(from, 0)
        let hi = min(to, heightPx)
        guard lo < hi else { return nil }
        let data = bytes.subdata(in: (lo * widthPx)..<(hi * widthPx))
        guard let cgImage = SD.grayCGImage(data, width: widthPx, height: hi - lo) else { return nil }
        return SD.GrayImage(bytes: data, widthPx: widthPx, heightPx: hi - lo, originPx: CGPoint(x: originPx.x, y: originPx.y + CGFloat(lo)),
                            cgImage: cgImage)
    }
}

extension SD.Observation {
    /// The stored 16-byte look of every tile under `rect`, or nil when a tile is not stored.
    func looks(of rect: CGRect, in grid: SD.TileGrid) -> [ArraySlice<UInt8>]? {
        var out: [ArraySlice<UInt8>] = []
        for tile in grid.tiles(in: rect) {
            let offset = (tile - firstTile) * 16
            guard offset >= 0, offset + 16 <= tileSignatures.count else { return nil }
            out.append(tileSignatures[offset..<(offset + 16)])
        }
        return out
    }
}

// MARK: - Candidates

extension SD {
    nonisolated(unsafe) static let longTokenRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9_\\-]{14,}", options: [])
    nonisolated(unsafe) static let zipCodeRegex = try! NSRegularExpression(pattern: "(?<![\\d$€£.,])\\d{5}(?![\\d.,])", options: [])

    /// Whether a fast-read line deserves an accurate read although nothing was found in it:
    /// an "@" (or ©/®, which it is often misread as), more than six digits, a five-digit number
    /// standing alone, or a long token with a digit, an underscore or an inner capital.
    static func isSensitiveCandidate(_ text: String) -> Bool {
        for c in text where "@©®".contains(c) {
            return true
        }
        if text.filter(\.isNumber).count > 6 { return true }
        let whole = NSRange(text.startIndex..., in: text)
        if zipCodeRegex.firstMatch(in: text, options: [], range: whole) != nil { return true }
        for m in longTokenRegex.matches(in: text, options: [], range: whole) {
            guard let r = Range(m.range, in: text) else { continue }
            let token = text[r]
            if token.contains(where: \.isNumber) { return true }
            if foundationContains(token, "_") { return true }
            let rest = token[(token.index(token.startIndex, offsetBy: 1, limitedBy: token.endIndex) ?? token.endIndex)...]
            if rest.contains(where: \.isUppercase) { return true }
        }
        return false
    }

    /// Fast lines worth an accurate read, with what the classifier found in them.
    static func sensitiveCandidates(_ lines: [ReadLine]) -> [(line: ReadLine, matches: [PatternMatch])] {
        let ranges = findSensitiveRanges(inFrame: lines.map { (text: $0.text.string, rect: $0.rect) })
        var out: [(line: ReadLine, matches: [PatternMatch])] = []
        for (i, line) in lines.enumerated() {
            if i == ranges.count { break }
            if !ranges[i].isEmpty || isSensitiveCandidate(line.text.string) {
                out.append((line: line, matches: ranges[i]))
            }
        }
        return out
    }

    /// Image rows covering `rects` with 0.6 line height of margin above and below.
    static func candidateRows(_ rects: [CGRect], in image: GrayImage) -> (Int, Int) {
        let top = rects.map { $0.minY + $0.height * -0.6 }.min()!
        let bottom = rects.map { $0.maxY + $0.height * 0.6 }.max()!
        let oy = image.originPx.y
        return (Int((top - oy).rounded(.down)), Int((bottom - oy).rounded(.up)))
    }

    /// `range` widened to the whitespace-delimited word around it.
    static func wordRange(around range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lo = range.lowerBound
        while lo > text.startIndex {
            let before = text.index(before: lo)
            if text[before].isWhitespace { break }
            lo = before
        }
        var hi = range.upperBound
        while hi < text.endIndex {
            if text[hi].isWhitespace { break }
            hi = text.index(after: hi)
        }
        return lo..<hi
    }

    // MARK: Ink

    /// `rect` fitted to the glyphs it covers within its line: columns with ink (pixels that differ
    /// from the background, the most common shade, by 29 or more) are found from each edge
    /// towards the middle — or, with `canGrow`, the edges move outwards over ink up to one height
    /// with gaps of at most a quarter height — and rows are kept where the ink is neither too
    /// sparse nor a solid rule. Falls back to `rect` grown by 0.4 × height and 0.15 × height.
    static func snapToInk(_ rect: CGRect, lineRect: CGRect, in image: GrayImage, canGrow: Bool) -> CGRect {
        let tallest = lineRect.height <= rect.height ? rect.height : lineRect.height
        let h = tallest <= 4 ? 4 : tallest
        let ox = image.originPx.x
        let oy = image.originPx.y
        let y0 = max(0, Int((lineRect.minY - oy).rounded(.down)))
        let y1 = min(image.heightPx, Int((lineRect.maxY - oy).rounded(.up)))
        let pad = Int(h)
        let x0 = max(0, Int(rect.minX - ox) - pad * 2)
        let x1 = min(image.widthPx, Int(rect.maxX - ox) + pad * 2)
        let fallback = rect.insetBy(dx: h * -0.4, dy: h * -0.15)
        guard y1 - y0 >= 3, x1 - x0 >= 3 else { return fallback }
        return image.bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CGRect in
            let px = buffer.bindMemory(to: UInt8.self)
            let rowBytes = image.widthPx
            var hist = [Int](repeating: 0, count: 256)
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    hist[Int(px[y * rowBytes + x])] += 1
                }
            }
            var background = 0
            for v in 1..<256 where hist[background] < hist[v] { background = v }
            var ink = [Bool](repeating: false, count: x1 - x0)
            for x in x0..<x1 {
                for y in y0..<y1 where abs(Int(px[y * rowBytes + x]) - background) >= 29 {
                    ink[x - x0] = true
                    break
                }
            }
            func isInk(_ x: Int) -> Bool { x >= x0 && x < x1 ? ink[x - x0] : false }
            let maxGap = max(2, Int(h * 0.25))
            func extend(from start: Int, step: Int, limit: Int) -> Int {
                var position = start
                if position == limit { return position }
                outer: while true {
                    var gap = 0
                    var p = position
                    while true {
                        let next = p + step
                        if isInk(next) {
                            position = next
                            if next == limit { return limit }
                            continue outer
                        }
                        if maxGap < gap + 1 { return position }
                        if next == limit { return position }
                        gap += 1
                        p = next
                    }
                }
            }
            let a = Int(rect.minX - ox)
            let b = Int(rect.maxX - ox) - 1
            let mid = (a + b) / 2
            var left = a
            if isInk(a) {
                if canGrow { left = extend(from: a, step: -1, limit: max(a - pad, x0)) }
            } else if a < mid {
                left = mid
                for x in a..<mid where isInk(x) {
                    left = x
                    break
                }
            }
            var right = b
            if isInk(b) {
                if canGrow { right = extend(from: b, step: 1, limit: min(b + pad, x1 - 1)) }
            } else if mid < b {
                right = mid
                var x = b
                while mid < x {
                    if isInk(x) {
                        right = x
                        break
                    }
                    x -= 1
                }
            }
            guard left < right, isInk(left) || isInk(right) else { return fallback }
            let width = right - left + 1
            let minInk = width > 149 ? width / 50 : 3
            var top = Int.max
            var bottom = Int.min
            for y in y0..<y1 {
                var count = 0
                for x in left...right where abs(Int(px[y * rowBytes + x]) - background) >= 29 {
                    count += 1
                }
                if count >= minInk && count < (width * 9) / 10 {
                    top = min(y, top)
                    bottom = max(y, bottom)
                }
            }
            guard bottom >= top else { return fallback }
            let padX = Swift.max(h * 0.12, 2)
            let padY = Swift.max(h * 0.1, 2)
            return CGRect(x: ox + CGFloat(left) - padX, y: oy + CGFloat(top) - padY,
                          width: padX + padX + CGFloat(width), height: padY + padY + CGFloat(bottom - top + 1))
        }
    }

    // MARK: Accurate pass

    /// The findings of one line's matches: each match boxed by the recognizer — inside its word's
    /// box, by character position, when the match is part of a longer word — then snapped to ink.
    private static func findings(of line: ReadLine, matches: [PatternMatch], in image: GrayImage) -> [Finding] {
        let text = line.text.string
        var out: [Finding] = []
        for match in matches {
            let matched = String(text[match.range])
            let word = wordRange(around: match.range, in: text)
            var rect: CGRect
            if word != match.range, let box = try? line.text.boundingBox(for: word) {
                let r = line.toFrame(box.boundingBox)
                let n = Double(text.distance(from: word.lowerBound, to: word.upperBound))
                let a = Double(text.distance(from: word.lowerBound, to: match.range.lowerBound)) / n
                let b = Double(text.distance(from: word.lowerBound, to: match.range.upperBound)) / n
                let pad = r.height * 0.15
                rect = CGRect(x: r.minX + a * r.width - pad, y: r.minY, width: pad + pad + (b - a) * r.width, height: r.height)
                rect = snapToInk(rect, lineRect: line.rect, in: image, canGrow: false)
            } else {
                if let box = try? line.text.boundingBox(for: match.range) {
                    rect = line.toFrame(box.boundingBox)
                } else {
                    rect = line.rect
                }
                rect = snapToInk(rect, lineRect: line.rect, in: image, canGrow: true)
            }
            out.append(Finding(kind: match.kind, text: matched, key: foldedKey(matched), rect: rect))
        }
        return out
    }

    /// Reads the rows around `rowsOf` with the accurate recognizer and returns its lines and
    /// findings; the fast candidates' own findings are added where nothing overlaps them, or
    /// replace an overlapping finding whose key they extend.
    static func readAccurately(_ image: GrayImage, rowsOf rects: [CGRect], fastCandidates: [(line: ReadLine, matches: [PatternMatch])],
                               matching: TextMatching) -> (lines: [RecognizedLine], findings: [Finding]) {
        let (lo, hi) = candidateRows(rects, in: image)
        guard let band = image.rows(lo, hi) else { return ([], []) }
        let start = CFAbsoluteTimeGetCurrent()
        let accurate = recognizeText(band, level: .accurate)
        let stats = accurateTierStats
        let end = CFAbsoluteTimeGetCurrent()
        let pixels = band.widthPx * band.heightPx
        stats.lock.lock()
        stats.seconds = (end - start) + stats.seconds
        stats.pixels = stats.pixels + pixels
        stats.lock.unlock()

        let matchesPerLine: [[PatternMatch]]
        switch matching {
        case .rule(let rule):
            var perLine: [[PatternMatch]] = []
            for line in accurate {
                let text = line.text.string
                let subject = matchingSubject(text)
                let results = rule.regex.matches(in: subject, options: [], range: NSRange(location: 0, length: (subject as NSString).length))
                let spans = results.map { TextSpan(kind: rule.kind, priority: rule.priority, range: $0.range) }
                perLine.append(patternMatches(spans, in: text))
            }
            matchesPerLine = perLine
        case .sensitive(let fastLines):
            var missing: [ReadLine] = []
            for fast in fastLines {
                let isReadAgain = accurate.contains { acc in
                    !(fast.rect.height * 0.5 > acc.rect.intersection(fast.rect).height) && acc.rect.intersects(fast.rect)
                }
                if !isReadAgain { missing.append(fast) }
            }
            let context = accurate + missing
            let ranges = findSensitiveRanges(inFrame: context.map { (text: $0.text.string, rect: $0.rect) })
            matchesPerLine = Array(ranges.prefix(accurate.count))
        }

        var lines: [RecognizedLine] = []
        var findings: [Finding] = []
        for (line, matches) in zip(accurate, matchesPerLine) {
            let text = line.text.string
            lines.append(RecognizedLine(text: text, key: foldedKey(text), rect: line.rect))
            findings.append(contentsOf: Self.findings(of: line, matches: matches, in: image))
        }
        for candidate in fastCandidates {
            let fastFindings = candidate.matches.isEmpty ? [] : Self.findings(of: candidate.line, matches: candidate.matches, in: image)
            for found in fastFindings {
                var overlapped = false
                for (j, existing) in findings.enumerated() where existing.rect.intersects(found.rect) {
                    if existing.key.count < found.key.count && foundationContains(found.key, existing.key) {
                        findings[j] = Finding(kind: found.kind, text: found.text, key: found.key, rect: existing.rect.union(found.rect))
                    }
                    overlapped = true
                    break
                }
                if !overlapped { findings.append(found) }
            }
        }
        return (lines, findings)
    }

    // MARK: Entry points

    /// Lines and findings of one crop.
    static func readText(_ image: GrayImage) -> (lines: [RecognizedLine], findings: [Finding]) {
        let enhanced = image.withLocalContrast(isDimmedOnly: true)
        let fast = recognizeText(enhanced, level: .fast)
        var lines = fast.map { RecognizedLine(text: $0.text.string, key: foldedKey($0.text.string), rect: $0.rect) }
        let candidates = sensitiveCandidates(fast)
        var findings: [Finding] = []
        if !candidates.isEmpty {
            let read = readAccurately(enhanced, rowsOf: candidates.map(\.line.rect), fastCandidates: candidates, matching: .sensitive(fastLines: fast))
            lines.append(contentsOf: read.lines)
            findings = read.findings
        }

        let small = fast.filter { $0.rect.height < 15 }
        guard options.enlargesSmallText, !small.isEmpty else { return (lines, findings) }
        let (lo, hi) = candidateRows(small.map(\.rect), in: enhanced)
        guard let band = enhanced.rows(lo, hi) else { return (lines, findings) }
        let minHeight = small.map(\.rect.height).min()!
        var scale: CGFloat = 30
        if !(minHeight < 1) {
            scale = Swift.max(30 / minHeight, 2)
        }
        scale = Swift.min(scale, 3)
        let scaled = band.resampled(by: scale)
        let fastSmall = recognizeText(scaled, level: .fast)
        let inverse = 1 / scale
        func unscaled(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * inverse, y: r.minY * inverse, width: r.width * inverse, height: r.height * inverse)
        }
        lines.append(contentsOf: fastSmall.map { RecognizedLine(text: $0.text.string, key: foldedKey($0.text.string), rect: unscaled($0.rect)) })
        let smallCandidates = sensitiveCandidates(fastSmall)
        guard !smallCandidates.isEmpty else { return (lines, findings) }
        let read = readAccurately(scaled, rowsOf: smallCandidates.map(\.line.rect), fastCandidates: smallCandidates,
                                  matching: .sensitive(fastLines: fastSmall))
        lines.append(contentsOf: read.lines.map { RecognizedLine(text: $0.text, key: $0.key, rect: unscaled($0.rect)) })
        for found in read.findings {
            let rect = unscaled(found.rect)
            let isKnown = findings.contains { $0.rect.intersects(rect) && foundationContains($0.key, found.key) }
            if !isKnown {
                findings.append(Finding(kind: found.kind, text: found.text, key: found.key, rect: rect))
            }
        }
        return (lines, findings)
    }

    /// Findings of a custom phrase in a crop whose lines (`lines`, from `readText`) mention it:
    /// the rows of those lines are read again (enlarged when the text is small) and matched
    /// against the phrase only.
    static func readPhrase(_ image: GrayImage, lines: [RecognizedLine], phrase: PhraseLayer) -> [Finding] {
        let hits = lines.filter { line in phrase.candidateKeys.contains { foundationContains(line.key, $0) } }
        let rects = hits.map(\.rect)
        guard !rects.isEmpty else { return [] }
        let enhanced = image.withLocalContrast(isDimmedOnly: true)
        let (lo, hi) = candidateRows(rects, in: enhanced)
        guard let band = enhanced.rows(lo, hi) else { return [] }
        let minHeight = rects.map(\.height).min()
        var scale: CGFloat = 1
        if options.enlargesSmallText, let minHeight, minHeight < 15 {
            var s: CGFloat = 30
            if 1 <= minHeight {
                s = Swift.max(30 / minHeight, 2)
            }
            scale = Swift.min(s, 3)
        }
        let scaled = band.resampled(by: scale)
        let fast = recognizeText(scaled, level: .fast)
        var fastHits: [ReadLine] = []
        for line in fast {
            let key = foldedKey(line.text.string)
            if phrase.candidateKeys.contains(where: { foundationContains(key, $0) }) {
                fastHits.append(line)
            }
        }
        let rule = phrase.rule
        let fastCandidates = fastHits.map { line -> (line: ReadLine, matches: [PatternMatch]) in
            let text = line.text.string
            let subject = matchingSubject(text)
            let results = rule.regex.matches(in: subject, options: [], range: NSRange(location: 0, length: (subject as NSString).length))
            let spans = results.map { TextSpan(kind: rule.kind, priority: rule.priority, range: $0.range) }
            return (line: line, matches: patternMatches(spans, in: text))
        }
        let scaledRects = rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        let read = readAccurately(scaled, rowsOf: scaledRects, fastCandidates: fastCandidates, matching: .rule(rule))
        let inverse = 1 / scale
        return read.findings.map {
            Finding(kind: $0.kind, text: $0.text, key: $0.key,
                    rect: CGRect(x: $0.rect.minX * inverse, y: $0.rect.minY * inverse, width: $0.rect.width * inverse, height: $0.rect.height * inverse))
        }
    }
}

extension SD.PhraseLayer {
    /// A custom phrase: matched as whole words ignoring case, accents and width, any whitespace
    /// between its words optional; found lines are those whose key contains one of the phrase's
    /// word keys longer than two characters (or the whole phrase's key).
    init(phrase: String) {
        let folded = phrase.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        var pattern = "(?<![\\p{L}\\p{N}])"
        pattern.append(words.joined(separator: "\\s*"))
        pattern.append("(?![\\p{L}\\p{N}])")
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        var keys = phrase.split(whereSeparator: \.isWhitespace).map { SD.foldedKey(String($0)) }.filter { $0.count > 2 }
        if keys.isEmpty {
            let whole = SD.foldedKey(phrase)
            keys = whole.isEmpty ? [] : [whole]
        }
        var seed = 1.description
        seed.append("|")
        seed.append(folded.lowercased())
        var id = "phrase-"
        id.append(SD.shortHash(seed))
        self.init(phrase: phrase, id: id, rule: SD.PatternRule(kind: "custom", priority: 0, regex: regex), candidateKeys: keys)
    }
}
