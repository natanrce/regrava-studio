@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import RegravaCore

/// `CursorAnalysis.detectHoverChanges`: reads the screen video where the mouse moved and
/// reports when something under the cursor lit up, as hovering a menu item or a button does.
/// Times are recording ms, ascending.
public enum CursorHoverDetector {
    /// `HoverDetector.Settings`.
    struct Settings {
        var probeHalfSizePt = 8.0
        var lookBackMs = 120.0
        var stabilityLookBackMs = 150.0
        var changedThreshold = 10
        var coherenceFactor = 0.35
        var minimumCoherenceTolerance = 6
        var minimumChanged = 0.4
        var minimumCoherent = 0.3
        var minimumQuadrants = 3
        var quadrantThreshold = 0.15
        var maximumPriorChange = 0.08
        var scrollHalfSizePt = 24.0
        var scrollMaxShiftPt = 32.0
        var scrollExplainsRatio = 0.5
        var minimumMovePt = 3.0
        var freeMovementWindowMs = 150.0
        var clickBeforeMs = 300.0
        var clickAfterMs = 80.0
        var spanJoinGapMs = 1000.0
    }

    /// A decoded frame: 8-bit luma and interleaved half-size chroma (`YCbCrFrame`).
    final class Frame {
        let timeMs: Double
        let width: Int, height: Int
        let luma: [UInt8]
        let chroma: [UInt8]
        let chromaWidth: Int

        init(timeMs: Double, width: Int, height: Int, luma: [UInt8], chroma: [UInt8], chromaWidth: Int) {
            self.timeMs = timeMs
            self.width = width
            self.height = height
            self.luma = luma
            self.chroma = chroma
            self.chromaWidth = chromaWidth
        }

        @inline(__always) func y(_ x: Int, _ y: Int) -> Int { Int(luma[y * width + x]) }
        @inline(__always) func cbcr(_ x: Int, _ y: Int) -> (Int, Int) {
            let i = (y / 2) * chromaWidth * 2 + (x / 2) * 2
            return (Int(chroma[i]), Int(chroma[i + 1]))
        }
    }

    public static func detect(video: URL, events: [MouseEvent], pointPixelScale: Double, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Double] {
        let settings = Settings()
        let moves = events.filter { $0.kind == .move }.sorted { $0.timeMs < $1.timeMs }
        let clicks = events.filter { $0.kind == .down || $0.kind == .up }.map(\.timeMs).sorted()
        guard !moves.isEmpty else { return [] }
        let spans = movementSpans(moves, joinGapMs: settings.spanJoinGapMs, tailMs: settings.freeMovementWindowMs)
        guard !spans.isEmpty else { return [] }

        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let natural = try await track.load(.naturalSize)
        // Decoded at no more than 1 px per point.
        let scale = min(1 / max(pointPixelScale, 0.0001), 1)
        let width = max(Int((natural.width * scale).rounded()), 2) & ~1
        let height = max(Int((natural.height * scale).rounded()), 2) & ~1
        let pxPerPt = pointPixelScale * scale
        let frameScale = Double(width) / max(natural.width, 1)
        let total = max(1, spans.reduce(0) { $0 + ($1.1 - $1.0) })
        return try await BlockingWork.run("hover detection") { cancellation in
            var processed = 0.0
            var changes: [Double] = []

            for (start, end) in spans {
                try cancellation.check()
                let reader = try AVAssetReader(asset: asset)
                // Read from before the span so the history holds the stability frames.
                let from = max(0, start - settings.lookBackMs - settings.stabilityLookBackMs - 1000)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: from / 1000, preferredTimescale: 600), end: CMTime(seconds: end / 1000, preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else { continue }
                var history: [Frame] = []
                var lastChange = -Double.infinity
                while let sample = output.copyNextSampleBuffer() {
                    try cancellation.check()
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
                    guard let buffer = CMSampleBufferGetImageBuffer(sample), let frame = copyFrame(buffer, timeMs: t) else { continue }
                    // Keep the newest frame at or before t − 270 ms, and everything after it.
                    let horizon = t - settings.lookBackMs - settings.stabilityLookBackMs
                    while history.count > 1 && history[1].timeMs <= horizon { history.removeFirst() }
                    if t >= start && t - lastChange >= settings.lookBackMs, let cursor = position(atMs: t, moves: moves) {
                        let px = (cursor.x * frameScale, cursor.y * frameScale)
                        if change(at: t, frame: frame, history: history, cursorPx: px, pxPerPt: pxPerPt, moves: moves, clicks: clicks, pointPixelScale: pointPixelScale, settings: settings) {
                            changes.append(t)
                            lastChange = t
                        }
                    }
                    history.append(frame)
                    if t >= start { progress(min(1, (processed + min(t, end) - start) / total)) }
                }
                processed += end - start
                progress(min(1, processed / total))
            }
            return changes.sorted()
        }
    }

    /// `CursorPath.movementSpans(joinGapMs:tailMs:)`.
    static func movementSpans(_ moves: [MouseEvent], joinGapMs: Double, tailMs: Double) -> [(Double, Double)] {
        var spans: [(Double, Double)] = []
        for move in moves {
            if let last = spans.last, move.timeMs - last.1 <= joinGapMs {
                spans[spans.count - 1].1 = move.timeMs + tailMs
            } else {
                spans.append((move.timeMs, move.timeMs + tailMs))
            }
        }
        return spans
    }

    /// Linear between moves; nil before the first.
    static func position(atMs t: Double, moves: [MouseEvent]) -> Vec2? {
        guard let first = moves.first, t >= first.timeMs else { return nil }
        var lo = 0, hi = moves.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if moves[mid].timeMs <= t { lo = mid } else { hi = mid - 1 } }
        let a = moves[lo]
        guard lo + 1 < moves.count else { return a.position }
        let b = moves[lo + 1]
        let f = (t - a.timeMs) / max(b.timeMs - a.timeMs, 0.0001)
        return Vec2(a.position.x + (b.position.x - a.position.x) * f, a.position.y + (b.position.y - a.position.y) * f)
    }

    private static func copyFrame(_ buffer: CVPixelBuffer, timeMs: Double) -> Frame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var luma = [UInt8](repeating: 0, count: w * h)
        var chroma = [UInt8](repeating: 0, count: cw * ch * 2)
        luma.withUnsafeMutableBytes { dst in
            for row in 0..<h { memcpy(dst.baseAddress! + row * w, yBase + row * yStride, w) }
        }
        chroma.withUnsafeMutableBytes { dst in
            for row in 0..<ch { memcpy(dst.baseAddress! + row * cw * 2, cBase + row * cStride, cw * 2) }
        }
        return Frame(timeMs: timeMs, width: w, height: h, luma: luma, chroma: chroma, chromaWidth: cw)
    }

    // MARK: HoverDetector.change

    private static func change(at t: Double, frame: Frame, history: [Frame], cursorPx: (Double, Double), pxPerPt: Double, moves: [MouseEvent], clicks: [Double], pointPixelScale: Double, settings: Settings) -> Bool {
        // 1. The mouse moved at least 3 pt over the last 150 ms.
        guard freeMovementPt(endingAt: t, windowMs: settings.freeMovementWindowMs, moves: moves, pointPixelScale: pointPixelScale) >= settings.minimumMovePt else { return false }
        // 2. No click from 300 ms before to 80 ms after.
        let firstClick = firstIndex(in: clicks) { $0 >= t - settings.clickBeforeMs }
        guard firstClick == clicks.count || !(clicks[firstClick] <= t + settings.clickAfterMs) else { return false }
        // 3. The frame 120 ms before, and the one 270 ms before.
        guard let beforeIndex = history.lastIndex(where: { $0.timeMs <= t - settings.lookBackMs }) else { return false }
        let before = history[beforeIndex]
        guard let earlier = history[...beforeIndex].last(where: { $0.timeMs <= t - settings.lookBackMs - settings.stabilityLookBackMs }) else { return false }
        // 4. Enough of the probe changed, coherently, in at least 3 quadrants.
        let cmp = compare(before, frame, around: cursorPx, pxPerPt: pxPerPt, settings: settings)
        guard cmp.changed >= settings.minimumChanged, cmp.coherent >= settings.minimumCoherent,
              cmp.quadrants.filter({ $0 >= settings.quadrantThreshold }).count >= settings.minimumQuadrants else { return false }
        // 5. Calm before it.
        if earlier !== before {
            guard compare(earlier, before, around: cursorPx, pxPerPt: pxPerPt, settings: settings).changed <= settings.maximumPriorChange else { return false }
        }
        // 6. Not a scroll.
        return !isExplainedByScrolling(from: before, to: frame, around: cursorPx, pxPerPt: pxPerPt, settings: settings)
    }

    /// First index whose element passes `predicate`, for a predicate that is false then true
    /// along the sorted array; `array.count` when none does.
    private static func firstIndex<T>(in array: [T], where predicate: (T) -> Bool) -> Int {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(array[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// `CursorPath.freeMovementPt(endingAtMs:windowMs:)`: path length of the moves in (t − w, t].
    /// `moves` is sorted by time.
    static func freeMovementPt(endingAt t: Double, windowMs: Double, moves: [MouseEvent], pointPixelScale: Double) -> Double {
        var distance = 0.0
        var previous: Vec2?
        let first = firstIndex(in: moves) { $0.timeMs > t - windowMs - 50 }
        for move in moves[first...] {
            guard move.timeMs <= t else { break }
            if let previous, move.timeMs > t - windowMs {
                distance += hypot(move.position.x - previous.x, move.position.y - previous.y) / pointPixelScale
            }
            previous = move.position
        }
        return distance
    }

    struct Comparison {
        var changed = 0.0
        var coherent = 0.0
        var quadrants: [Double] = []
    }

    /// `HoverDetector.compare`: changed pixels in the probe square, how many move by about the
    /// median colour delta, and that share per quadrant.
    static func compare(_ a: Frame, _ b: Frame, around c: (Double, Double), pxPerPt: Double, settings: Settings) -> Comparison {
        let r = max(2, Int((settings.probeHalfSizePt * pxPerPt).rounded()))
        let cx = Int(c.0.rounded()), cy = Int(c.1.rounded())
        let x0 = max(0, cx - r), x1 = min(min(a.width, b.width) - 1, cx + r)
        let y0 = max(0, cy - r), y1 = min(min(a.height, b.height) - 1, cy + r)
        guard x0 <= x1, y0 <= y1 else { return Comparison() }
        var totals = [Int](repeating: 0, count: 4)
        var deltas: [(Int, Int, Int, Int)] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let q = (x >= cx ? 1 : 0) + (y >= cy ? 2 : 0)
                totals[q] += 1
                let dY = b.y(x, y) - a.y(x, y)
                let (ca, ra) = a.cbcr(x, y), (cb, rb) = b.cbcr(x, y)
                let dCb = cb - ca, dCr = rb - ra
                if abs(dY) + abs(dCb) + abs(dCr) >= settings.changedThreshold { deltas.append((dY, dCb, dCr, q)) }
            }
        }
        let total = totals.reduce(0, +)
        guard !deltas.isEmpty, total > 0 else { return Comparison(quadrants: [0, 0, 0, 0]) }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let mY = median(deltas.map(\.0)), mCb = median(deltas.map(\.1)), mCr = median(deltas.map(\.2))
        let tolerance = max(settings.minimumCoherenceTolerance, Int((settings.coherenceFactor * Double(abs(mY) + abs(mCb) + abs(mCr))).rounded()))
        var coherent = [Int](repeating: 0, count: 4)
        for d in deltas where abs(d.0 - mY) + abs(d.1 - mCb) + abs(d.2 - mCr) <= tolerance { coherent[d.3] += 1 }
        return Comparison(
            changed: Double(deltas.count) / Double(total),
            coherent: Double(coherent.reduce(0, +)) / Double(total),
            quadrants: (0..<4).map { totals[$0] == 0 ? 0 : Double(coherent[$0]) / Double(totals[$0]) }
        )
    }

    /// `HoverDetector.isExplainedByScrolling`: some vertical or horizontal shift of the region
    /// matches better than half the unshifted luma difference.
    static func isExplainedByScrolling(from a: Frame, to b: Frame, around c: (Double, Double), pxPerPt: Double, settings: Settings) -> Bool {
        let R = Int((settings.scrollHalfSizePt * pxPerPt).rounded()), S = Int((settings.scrollMaxShiftPt * pxPerPt).rounded())
        let k = max(1, Int(pxPerPt.rounded()))
        let w = min(a.width, b.width), h = min(a.height, b.height)
        let cx = Int(c.0.rounded()), cy = Int(c.1.rounded())
        let x0 = max(S, cx - R), x1 = min(w - 1 - S, cx + R)
        let y0 = max(S, cy - R), y1 = min(h - 1 - S, cy + R)
        guard x0 <= x1, y0 <= y1 else { return false }
        func sad(_ dx: Int, _ dy: Int) -> Int {
            var sum = 0
            var y = y0
            while y <= y1 {
                var x = x0
                while x <= x1 {
                    sum += abs(b.y(x, y) - a.y(x - dx, y - dy))
                    x += k
                }
                y += k
            }
            return sum
        }
        let base = sad(0, 0)
        guard base >= 1 else { return false }
        var best = Int.max
        var s = -S
        while s <= S {
            if s != 0 {
                best = min(best, sad(0, s), sad(s, 0))
            }
            s += k
        }
        return settings.scrollExplainsRatio * Double(base) > Double(best)
    }
}
