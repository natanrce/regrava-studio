import CoreGraphics
import CoreVideo
import Foundation

// Tiles, block signatures, stripe profiles, reading bands and vertical shift measurement.

extension SD.TileGrid {
    /// Row-major indices of the 32 px tiles a rect touches (clipped to the frame).
    func tiles(in rect: CGRect) -> [Int] {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: CGFloat(widthPx), height: CGFloat(heightPx)))
        guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
        let x0 = Int(r.minX) / 32
        let x1 = min(Int(r.maxX.rounded(.up) - 1) / 32, tilesX - 1)
        let y0 = Int(r.minY) / 32
        let y1 = min(Int(r.maxY.rounded(.up) - 1) / 32, tilesY - 1)
        precondition(x0 <= x1 && y0 <= y1)
        var out: [Int] = []
        for y in y0...y1 {
            for x in x0...x1 { out.append(y * tilesX + x) }
        }
        return out
    }

    /// Which of the 8 vertical stripes an x falls in.
    func stripe(ofX x: CGFloat) -> Int {
        let width = (widthPx + 7) / 8
        return min(max(Int(x) / width, 0), 7)
    }
}

extension SD {
    /// Means of the 8×8 luma blocks (16 per tile, `tile*16 + (by&3)*4 + (bx&3)`) and, per stripe, the
    /// sum of each pixel row (`stripeProfiles[stripe*height + y]`).
    static func computeSignatures(luma: UnsafePointer<UInt8>, rowBytes: Int, grid: TileGrid, blockSums: UnsafeMutablePointer<UInt32>,
                                  blockStripes: UnsafePointer<Int>, into: UnsafeMutablePointer<UInt8>, stripeProfiles: UnsafeMutablePointer<Int32>) {
        let width = grid.widthPx, height = grid.heightPx
        let blocksX = (width + 7) / 8
        let fullBlocksX = width / 8
        let blocksY = (height + 7) / 8
        stripeProfiles.update(repeating: 0, count: height * 8)
        for by in 0..<blocksY {
            blockSums.update(repeating: 0, count: blocksX)
            let y0 = by * 8
            let y1 = min(y0 + 8, height)
            for y in y0..<y1 {
                let row = luma + y * rowBytes
                for bx in 0..<fullBlocksX {
                    var s: UInt32 = 0
                    for k in 0..<8 { s &+= UInt32(row[bx * 8 + k]) }
                    blockSums[bx] &+= s
                    stripeProfiles[blockStripes[bx] * height + y] &+= Int32(bitPattern: s)
                }
                if fullBlocksX < blocksX {
                    var s: Int32 = 0
                    for x in (fullBlocksX * 8)..<width { s += Int32(row[x]) }
                    blockSums[fullBlocksX] &+= UInt32(bitPattern: s)
                    stripeProfiles[blockStripes[fullBlocksX] * height + y] &+= s
                }
            }
            let divisor = UInt32(truncatingIfNeeded: (y1 - y0) * 8)
            for bx in 0..<blocksX {
                let tile = (by >> 2) * grid.tilesX + (bx >> 2)
                into[tile * 16 + (by & 3) * 4 + (bx & 3)] = UInt8(truncatingIfNeeded: divisor == 0 ? 0 : blockSums[bx] / divisor)
            }
        }
    }

    /// Full-width bands to read for the due tile rows: each due row is widened by two rows up and
    /// down, touching rows join, and when the bands cover more than 45% of the frame height the
    /// whole frame is read instead.
    static func readingBands(dueRows: [Bool], grid: TileGrid) -> [CGRect] {
        let rows = grid.tilesY
        var expanded = [Bool](repeating: false, count: rows)
        for r in 0..<dueRows.count where dueRows[r] {
            let lo = max(r - 2, 0)
            let hi = min(r + 2, rows - 1)
            precondition(lo < rows)
            if lo <= hi { for k in lo...hi { expanded[k] = true } }
        }
        var bands: [CGRect] = []
        var r = 0
        while r < rows {
            if expanded[r] {
                var end = r
                while end < rows, expanded[end] { end += 1 }
                let maxY = min(end * 32, grid.heightPx)
                bands.append(CGRect(x: 0, y: Double(r * 32), width: Double(grid.widthPx), height: Double(maxY - r * 32)))
                r = end
            } else {
                r += 1
            }
        }
        var total: CGFloat = 0
        for b in bands { total += b.height }
        if Double(grid.heightPx) * 0.45 < total {
            return [CGRect(x: 0, y: 0, width: Double(grid.widthPx), height: Double(grid.heightPx))]
        }
        return bands
    }

    /// Vertical shift, in eighths of a pixel, that maps the current row profile onto the previous
    /// one (`current[y] ≈ previous[y + shift]`); `Int16.min` when no shift can be told. The height is
    /// measured in four quarters; quarters that agree within 2 px decide.
    static func measureVerticalShift(previous: UnsafePointer<Int32>, current: UnsafePointer<Int32>, height: Int, previousShift: Int,
                                     coarsePrevious: UnsafeMutablePointer<Int32>, coarseCurrent: UnsafeMutablePointer<Int32>,
                                     isShiftConfirmed: (Range<Int>, Int) -> Bool) -> Int16 {
        let coarse = height / 4
        for i in 0..<max(coarse, 0) {
            coarsePrevious[i] = previous[4 * i] &+ previous[4 * i + 2] &+ previous[4 * i + 1] &+ previous[4 * i + 3]
            coarseCurrent[i] = current[4 * i] &+ current[4 * i + 2] &+ current[4 * i + 1] &+ current[4 * i + 3]
        }
        let maxCoarse = min(coarse / 3, 80)

        /// Mean absolute difference of `current[y]` and `previous[y + shift]` over `lo..<hi`.
        func cost(_ cur: UnsafePointer<Int32>, _ prev: UnsafePointer<Int32>, _ lo: Int, _ hi: Int, _ shift: Int) -> Double {
            var sum = 0
            for y in lo..<hi {
                let a = cur[y], b = prev[y + shift]
                sum += Int(a > b ? UInt32(bitPattern: a &- b) : UInt32(bitPattern: b &- a))
            }
            return Double(lo == hi ? 0 : sum) / Double(hi - lo)
        }

        var parts: [Int16] = []
        parts.reserveCapacity(4)
        for part in 0..<4 {
            let lo = (height * part) / 4
            let hi = (height * (part + 1)) / 4
            let count = min(hi, height) - lo
            let half = (hi - lo) / 2
            var still = Double.infinity
            var result: Int16
            if count >= half {
                still = cost(current, previous, lo, min(hi, height), 0)
                if still < 60 {
                    parts.append(0)
                    continue
                }
            }
            // Coarse search on 4 px steps.
            let cLo = (height * part) / 16
            let cHi = (height * (part + 1)) / 16
            var costs: [Double] = []
            costs.reserveCapacity(2 * maxCoarse + 1)
            for s in -maxCoarse...maxCoarse {
                let start = max(-s, cLo)
                let end = min(cHi, coarse - s)
                let n = end - start
                if n < (cHi - cLo) >> 1 {
                    costs.append(.infinity)
                } else {
                    costs.append(cost(UnsafePointer(coarseCurrent), UnsafePointer(coarsePrevious), start, end, s))
                }
            }
            let limit = costs.min().map { $0 * 1.05 + 1.0 } ?? .infinity
            var bestCoarse = 0
            var bestDistance = Int.max
            for (j, c) in costs.enumerated() where c <= limit {
                let s = j - maxCoarse
                let distance = abs(4 * s - previousShift)
                if distance < bestDistance {
                    bestDistance = distance
                    bestCoarse = s
                }
            }
            // Fine search within ±4 px of the coarse shift.
            var best = 4 * bestCoarse
            var bestCost = Double.infinity
            for t in (4 * bestCoarse - 4)...(4 * bestCoarse + 4) {
                let start = max(-t, lo)
                let end = min(height - t, hi)
                if end - start >= half {
                    let c = cost(current, previous, start, end, t)
                    if c < bestCost {
                        best = t
                        bestCost = c
                    }
                }
            }
            if best == 0 || still * 0.35 <= bestCost {
                result = Int16.min
            } else if isShiftConfirmed(lo..<hi, best) {
                func around(_ t: Int) -> Double {
                    let start = max(-t, lo)
                    let end = min(height - t, hi)
                    if end - start < half { return .infinity }
                    return cost(current, previous, start, end, t)
                }
                let below = around(best - 1)
                let above = around(best + 1)
                var offset = 0.0
                if below.isFinite, above.isFinite {
                    let worst = above < below ? below : above
                    if bestCost < worst {
                        let v = (below - above) / ((worst - bestCost) + (worst - bestCost))
                        offset = -0.5 <= v ? Swift.min(v, 0.5) : -0.5
                    }
                }
                result = Int16(((offset + Double(best)) * 8.0).rounded())
            } else {
                result = 0
            }
            parts.append(result)
        }

        let moving = parts.filter { $0 & 0x7fff != 0 }
        if moving.isEmpty {
            return parts.contains(Int16.min) ? Int16.min : 0
        }
        var groups: [[Int16]] = []
        for v in moving {
            groups.append(moving.filter { (-16...16).contains(Int($0) - Int(v)) })
        }
        var largest = groups[0]
        for g in groups.dropFirst() where largest.count < g.count { largest = g }
        if largest.count < 2 && largest.count * 2 <= moving.count { return Int16.min }
        return largest.sorted()[largest.count / 2]
    }

    /// Confirms a measured shift on the pixels of one stripe: on every third row and column, the
    /// current frame must match the previous frame moved by the shift much better than unmoved
    /// and than moved by 3 px more or less.
    static func isShiftConfirmed(rows: Range<Int>, shift: Int, previous: CVPixelBuffer?, current: UnsafePointer<UInt8>, rowBytes: Int,
                                 stripe: Int, grid: TileGrid) -> Bool {
        guard let previous else { return true }
        let base = CVPixelBufferGetBaseAddressOfPlane(previous, 0)!.assumingMemoryBound(to: UInt8.self)
        let previousRowBytes = CVPixelBufferGetBytesPerRowOfPlane(previous, 0)
        let stripeWidth = (grid.widthPx + 7) / 8
        let x0 = stripe * stripeWidth
        let x1 = min((stripe + 1) * stripeWidth, grid.widthPx)
        var y = max(-shift + 3, rows.lowerBound)
        let yEnd = min(grid.heightPx - shift - 3, rows.upperBound)
        var unmoved = 0, moved = 0, movedLess = 0, movedMore = 0, count = 0
        while y < yEnd {
            var x = x0
            while x < x1 {
                let p = Int(current[y * rowBytes + x])
                unmoved += abs(p - Int(base[y * previousRowBytes + x]))
                let row = base + (y + shift) * previousRowBytes
                moved += abs(p - Int(row[x]))
                movedLess += abs(p - Int(row[x - 3 * previousRowBytes]))
                movedMore += abs(p - Int(row[x + 3 * previousRowBytes]))
                count += 1
                x += 3
            }
            y += 3
        }
        let factor = abs(shift) < 13 ? 3 : 8
        return moved < count * 6 && moved * factor < unmoved && moved * 3 < min(movedLess, movedMore)
    }
}
