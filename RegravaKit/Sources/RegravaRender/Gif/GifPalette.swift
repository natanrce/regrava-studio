import Dispatch
import Foundation

/// The colours of a GIF, with each colour's linear sRGB and OkLab values.
final class GifPalette: @unchecked Sendable {
    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    let colors: [RGB]
    let linear: UnsafeMutablePointer<GifColor>
    let oklab: UnsafeMutablePointer<GifColor>

    var count: Int { colors.count }

    init(colors: [RGB]) {
        self.colors = colors
        let capacity = max(colors.count, 1)
        linear = .allocate(capacity: capacity)
        oklab = .allocate(capacity: capacity)
        for (i, color) in colors.enumerated() {
            let lin = GifColorMath.linear(color.r, color.g, color.b)
            linear[i] = lin
            oklab[i] = GifColorMath.oklab(linear: lin)
        }
    }

    deinit {
        linear.deallocate()
        oklab.deallocate()
    }
}

/// Pixel counts and channel sums per 6-bit-per-channel RGB cell.
final class GifColorHistogram {
    static let cellCount = 1 << 18

    let counts: UnsafeMutablePointer<UInt64>
    /// r, g, b and an unused fourth sum per cell.
    let sums: UnsafeMutablePointer<UInt64>

    init() {
        counts = .allocate(capacity: Self.cellCount)
        counts.initialize(repeating: 0, count: Self.cellCount)
        sums = .allocate(capacity: Self.cellCount * 4)
        sums.initialize(repeating: 0, count: Self.cellCount * 4)
    }

    deinit {
        counts.deallocate()
        sums.deallocate()
    }

    @inline(__always)
    static func cell(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        Int(r >> 2) << 12 | Int(g >> 2) << 6 | Int(b >> 2)
    }

    /// Adds every `stride`-th pixel of every `stride`-th row.
    func add(_ pixels: GifFramePixels, stride: Int) {
        let bytesPerPixel = pixels.layout.bytesPerPixel
        let redOffset = pixels.layout.redOffset, blueOffset = pixels.layout.blueOffset
        var y = 0
        while y < pixels.height {
            var p = pixels.base + y * pixels.bytesPerRow
            var x = 0
            while x < pixels.width {
                let r = p[redOffset], g = p[1], b = p[blueOffset]
                let cell = Self.cell(r, g, b)
                counts[cell] += 1
                sums[cell * 4] += UInt64(r)
                sums[cell * 4 + 1] += UInt64(g)
                sums[cell * 4 + 2] += UInt64(b)
                p += bytesPerPixel * stride
                x += stride
            }
            y += stride
        }
    }

    func merge(_ other: GifColorHistogram) {
        for cell in 0..<Self.cellCount where other.counts[cell] != 0 {
            counts[cell] += other.counts[cell]
            for c in 0..<4 {
                sums[cell * 4 + c] += other.sums[cell * 4 + c]
            }
        }
    }
}

/// Builds a palette from a histogram: variance splits in OkLab, then weighted k-means.
enum GifPaletteBuilder {
    struct Item {
        var lab: GifColor
        var weight: Float
    }

    struct Box {
        var start: Int
        var end: Int
        var weight: Float
        var sum: GifColor
        var sumSquares: GifColor

        /// Sum of squared distances to the box mean.
        var error: Float {
            guard weight > 0 else { return 0 }
            return (sumSquares.x - sum.x * sum.x / weight)
                + (sumSquares.y - sum.y * sum.y / weight)
                + (sumSquares.z - sum.z * sum.z / weight)
        }
    }

    static func build(histogram: GifColorHistogram, maxColors: Int, kmeansIterations: Int) -> GifPalette {
        var items: [Item] = []
        for cell in 0..<GifColorHistogram.cellCount {
            let count = histogram.counts[cell]
            guard count != 0 else { continue }
            let n = Double(count)
            let r = GifColorMath.decode(Float(Double(histogram.sums[cell * 4]) / n) / 255)
            let g = GifColorMath.decode(Float(Double(histogram.sums[cell * 4 + 1]) / n) / 255)
            let b = GifColorMath.decode(Float(Double(histogram.sums[cell * 4 + 2]) / n) / 255)
            items.append(Item(lab: GifColorMath.oklab(linear: GifColor(x: r, y: g, z: b)), weight: Float(count)))
        }
        let labs: [GifColor]
        if maxColors < items.count {
            let centers = splitByVariance(&items, into: maxColors)
            labs = refineByKmeans(items: items, centers: centers, iterations: kmeansIterations)
        } else {
            labs = items.map(\.lab)
        }
        let colors = labs.map { lab -> GifPalette.RGB in
            let lin = GifColorMath.linear(oklab: lab)
            return GifPalette.RGB(
                r: GifColorMath.linearToSrgbByte(lin.x),
                g: GifColorMath.linearToSrgbByte(lin.y),
                b: GifColorMath.linearToSrgbByte(lin.z)
            )
        }
        return GifPalette(colors: colors)
    }

    static func makeBox(_ items: [Item], _ start: Int, _ end: Int) -> Box {
        var box = Box(start: start, end: end, weight: 0, sum: .zero, sumSquares: .zero)
        for item in items[start..<end] {
            let w = item.weight, c = item.lab
            box.weight += w
            box.sum.x += c.x * w
            box.sum.y += c.y * w
            box.sum.z += c.z * w
            box.sumSquares.x += c.x * c.x * w
            box.sumSquares.y += c.y * c.y * w
            box.sumSquares.z += c.z * c.z * w
        }
        return box
    }

    /// Splits the box with the largest error along its widest OkLab axis, at the cut that leaves
    /// the least total error, until there are `into` boxes or nothing left to split. Returns the
    /// box means.
    static func splitByVariance(_ items: inout [Item], into count: Int) -> [GifColor] {
        var boxes = [makeBox(items, 0, items.count)]
        while boxes.count < count {
            let candidates = boxes.indices.filter { boxes[$0].end - boxes[$0].start > 1 }
            guard var chosen = candidates.first else { break }
            for index in candidates.dropFirst() where boxes[chosen].error < boxes[index].error {
                chosen = index
            }
            let box = boxes[chosen]
            let w = box.weight
            guard w > 0, box.error > 0 else { break }
            let varianceX = box.sumSquares.x / w - (box.sum.x / w) * (box.sum.x / w)
            let varianceY = box.sumSquares.y / w - (box.sum.y / w) * (box.sum.y / w)
            let varianceZ = box.sumSquares.z / w - (box.sum.z / w) * (box.sum.z / w)
            let axis = varianceZ <= varianceX && varianceY <= varianceX ? 0 : (varianceZ > varianceY ? 2 : 1)
            switch axis {
            case 0: items[box.start..<box.end].sort { $0.lab.x < $1.lab.x }
            case 1: items[box.start..<box.end].sort { $0.lab.y < $1.lab.y }
            default: items[box.start..<box.end].sort { $0.lab.z < $1.lab.z }
            }
            var split = box.start + 1
            var bestCost = Float.infinity
            var lw: Float = 0
            var ls = GifColor.zero, lq = GifColor.zero
            for cut in (box.start + 1)..<box.end {
                let item = items[cut - 1]
                let iw = item.weight, c = item.lab
                lw += iw
                ls.x += c.x * iw
                ls.y += c.y * iw
                ls.z += iw * c.z
                lq.x += c.x * c.x * iw
                lq.y += c.y * c.y * iw
                lq.z += iw * (c.z * c.z)
                let rw = w - lw
                guard rw > 0 else { continue }
                let rsx = box.sum.x - ls.x, rsy = box.sum.y - ls.y, rsz = box.sum.z - ls.z
                let left = (lq.x - ls.x * ls.x / lw) + (lq.y - ls.y * ls.y / lw) + (lq.z - ls.z * ls.z / lw)
                let right = ((box.sumSquares.x - lq.x) - rsx * rsx / rw)
                    + ((box.sumSquares.y - lq.y) - rsy * rsy / rw)
                    + ((box.sumSquares.z - lq.z) - rsz * rsz / rw)
                let cost = left + right
                if cost < bestCost {
                    bestCost = cost
                    split = cut
                }
            }
            boxes[chosen] = makeBox(items, box.start, split)
            boxes.append(makeBox(items, split, box.end))
        }
        return boxes.map { GifColor(x: $0.sum.x / $0.weight, y: $0.sum.y / $0.weight, z: $0.sum.z / $0.weight) }
    }

    /// Weighted k-means over 16 fixed chunks of the items. A cluster whose heaviest item holds at
    /// least half its weight snaps to that item; an empty cluster keeps its center.
    static func refineByKmeans(items: [Item], centers: [GifColor], iterations: Int) -> [GifColor] {
        var centers = centers
        let k = centers.count
        let chunks = 16
        let chunkSize = (items.count + chunks - 1) / chunks
        guard iterations > 0 else { return centers }
        for _ in 0..<iterations {
            let sums = UnsafeMutablePointer<GifColor>.allocate(capacity: chunks * k)
            sums.initialize(repeating: .zero, count: chunks * k)
            let weights = UnsafeMutablePointer<Float>.allocate(capacity: chunks * k)
            weights.initialize(repeating: 0, count: chunks * k)
            let heaviestWeight = UnsafeMutablePointer<Float>.allocate(capacity: chunks * k)
            heaviestWeight.initialize(repeating: 0, count: chunks * k)
            let heaviestLab = UnsafeMutablePointer<GifColor>.allocate(capacity: chunks * k)
            heaviestLab.initialize(repeating: .zero, count: chunks * k)
            items.withUnsafeBufferPointer { items in
                centers.withUnsafeBufferPointer { centers in
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let lower = chunk * chunkSize
                        let upper = min(lower + chunkSize, items.count)
                        guard lower < upper else { return }
                        for i in lower..<upper {
                            let lab = items[i].lab, w = items[i].weight
                            var nearest = 0
                            var nearestDistance = Float.infinity
                            for c in 0..<k {
                                let d = lab.distanceSquared(to: centers[c])
                                if d < nearestDistance {
                                    nearestDistance = d
                                    nearest = c
                                }
                            }
                            let slot = chunk * k + nearest
                            sums[slot].x += lab.x * w
                            sums[slot].y += lab.y * w
                            sums[slot].z += w * lab.z
                            weights[slot] = w + weights[slot]
                            if heaviestWeight[slot] < w {
                                heaviestWeight[slot] = w
                                heaviestLab[slot] = lab
                            }
                        }
                    }
                }
            }
            for c in 0..<k {
                var heaviest: Float = 0
                var heaviestColor = GifColor.zero
                var sum = GifColor.zero
                var weight: Float = 0
                for chunk in 0..<chunks {
                    let slot = chunk * k + c
                    if heaviest < heaviestWeight[slot] {
                        heaviest = heaviestWeight[slot]
                        heaviestColor = heaviestLab[slot]
                    }
                    sum.x += sums[slot].x
                    sum.y += sums[slot].y
                    sum.z += sums[slot].z
                    weight += weights[slot]
                }
                guard weight > 0 else { continue }
                centers[c] = heaviest < weight * 0.5
                    ? GifColor(x: sum.x / weight, y: sum.y / weight, z: sum.z / weight)
                    : heaviestColor
            }
            sums.deallocate()
            weights.deallocate()
            heaviestWeight.deallocate()
            heaviestLab.deallocate()
        }
        return centers
    }
}

/// For every 6-bit-per-channel RGB cell, the nearest and second-nearest palette entries in OkLab,
/// measured from the cell's center.
final class GifNearestColorTable: @unchecked Sendable {
    /// Two indices per cell: `entries[cell * 2]` nearest, `entries[cell * 2 + 1]` second nearest.
    let entries: UnsafeMutablePointer<UInt8>

    init(palette: GifPalette) {
        let entries = UnsafeMutablePointer<UInt8>.allocate(capacity: GifColorHistogram.cellCount * 2)
        self.entries = entries
        let oklab = palette.oklab
        let count = palette.count
        DispatchQueue.concurrentPerform(iterations: 64) { r in
            let red = GifColorMath.srgbToLinear[r << 2 | 2]
            for g in 0..<64 {
                let green = GifColorMath.srgbToLinear[g << 2 | 2]
                for b in 0..<64 {
                    let blue = GifColorMath.srgbToLinear[b << 2 | 2]
                    let lab = GifColorMath.oklab(linear: GifColor(x: red, y: green, z: blue))
                    var best = 0, second = 0
                    var bestDistance = Float.infinity, secondDistance = Float.infinity
                    for i in 0..<count {
                        let d = lab.distanceSquared(to: oklab[i])
                        if d < secondDistance {
                            second = i
                            secondDistance = d
                        }
                        if d < bestDistance {
                            second = best
                            secondDistance = bestDistance
                            best = i
                            bestDistance = d
                        }
                    }
                    let cell = r << 12 | g << 6 | b
                    entries[cell * 2] = UInt8(best)
                    entries[cell * 2 + 1] = UInt8(second)
                }
            }
        }
    }

    deinit {
        entries.deallocate()
    }
}
