import Dispatch
import Foundation
import RegravaCore

/// One frame's pixels, read in place.
struct GifFramePixels {
    enum Layout {
        case rgb
        case bgra

        var bytesPerPixel: Int { self == .rgb ? 3 : 4 }
        var redOffset: Int { self == .rgb ? 0 : 2 }
        var blueOffset: Int { self == .rgb ? 2 : 0 }
    }

    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let layout: Layout
}

/// Blue-noise dithering between a pixel's nearest palette colour and the one on the other side of
/// it, when the pixel is not already close to a palette colour and the two colours are close.
struct GifDitherSettings {
    /// A pixel this close (OkLab) to its nearest palette colour is not dithered.
    var exactDistance: Float = 0.004
    /// The two colours are mixed only when they are at most this far apart.
    var maxSpread: Float = 0.2
    var strength: Float = 1
}

struct GifEncodingSettings {
    /// A pixel stays as shown while its colour is within this distance of the shown colour.
    var keepDistance: Float
    /// Largest error the LZW search may add on textured areas.
    var lossyDistance: Float
    /// Largest error the LZW search may add on flat areas.
    var lossyFlatDistance: Float
    /// Local lightness contrast at which an area counts as fully textured.
    var lossyTextureContrast: Float
    var dither: GifDitherSettings
    var maxColors: Int

    static let balanced = GifEncodingSettings(
        keepDistance: 0.015, lossyDistance: 0.15, lossyFlatDistance: 0.025, lossyTextureContrast: 0.08,
        dither: GifDitherSettings(), maxColors: 255
    )

    static let high = GifEncodingSettings(
        keepDistance: 0.01, lossyDistance: 0.1, lossyFlatDistance: 0.015, lossyTextureContrast: 0.08,
        dither: GifDitherSettings(), maxColors: 255
    )

    static func forMode(_ mode: GifQualityMode) -> GifEncodingSettings {
        mode == .high ? .high : .balanced
    }
}

struct GifEncodingStats: Equatable {
    var bytes: Int
    var writtenFrameCount: Int
}

/// Collects sample frames into a histogram for the palette.
final class GifPaletteSampler {
    private let histogram = GifColorHistogram()
    private let pixelStride: Int

    init(pixelStride: Int) {
        self.pixelStride = pixelStride
    }

    func add(_ pixels: GifFramePixels) {
        histogram.add(pixels, stride: pixelStride)
    }

    func makePalette(maxColors: Int) -> GifPalette {
        GifPaletteBuilder.build(histogram: histogram, maxColors: maxColors, kmeansIterations: 12)
    }
}

/// Maps a pixel to a palette index, dithering with the blue-noise thresholds.
struct GifPixelMapper {
    let palette: GifPalette
    let table: GifNearestColorTable
    let dither: GifDitherSettings

    @inline(__always)
    func map(_ r: UInt8, _ g: UInt8, _ b: UInt8, x: Int, y: Int, lab: GifColor) -> UInt8 {
        let cell = GifColorHistogram.cell(r, g, b) * 2
        let first = table.entries[cell], second = table.entries[cell + 1]
        let firstDistance = lab.distanceSquared(to: palette.oklab[Int(first)])
        let secondDistance = lab.distanceSquared(to: palette.oklab[Int(second)])
        let nearest = secondDistance < firstDistance ? second : first
        let nearestDistance = secondDistance < firstDistance ? secondDistance : firstDistance
        guard !(nearestDistance <= dither.exactDistance * dither.exactDistance), !(dither.strength <= 0) else {
            return nearest
        }
        let pixel = GifColorMath.linear(r, g, b)
        let shown = palette.linear[Int(nearest)]
        let error = GifColor(x: pixel.x - shown.x, y: pixel.y - shown.y, z: pixel.z - shown.z)
        // The colour on the other side of the pixel from its nearest palette colour.
        let mirrored = GifColorHistogram.cell(
            GifColorMath.linearToSrgbByte(pixel.x + error.x),
            GifColorMath.linearToSrgbByte(pixel.y + error.y),
            GifColorMath.linearToSrgbByte(pixel.z + error.z)
        )
        let other = table.entries[mirrored * 2]
        guard other != nearest else { return nearest }
        let spread = palette.oklab[Int(nearest)].distanceSquared(to: palette.oklab[Int(other)])
        guard !(dither.maxSpread * dither.maxSpread < spread) else { return nearest }
        let otherLinear = palette.linear[Int(other)]
        let step = GifColor(x: otherLinear.x - shown.x, y: otherLinear.y - shown.y, z: otherLinear.z - shown.z)
        let length = step.x * step.x + step.y * step.y + step.z * step.z
        guard length > 0 else { return nearest }
        let t = (error.x * step.x + error.y * step.y + error.z * step.z) / length
        let clamped = t < 1 ? (t >= 0 ? t : 0) : 1
        let threshold = GifBlueNoise.thresholds[(y & 63) * 64 + (x & 63)]
        return threshold < dither.strength * clamped ? other : nearest
    }
}

/// Writes a GIF frame by frame with one global palette. Each frame stores only the rectangle of
/// pixels that changed, with unchanged pixels transparent; frames with no change extend the delay
/// of the previous one.
final class GifStreamEncoder {
    /// Palette index of transparent pixels; palettes hold at most 255 colours.
    static let transparentIndex: UInt8 = 0xFF

    struct PendingFrame {
        var left: Int
        var top: Int
        var width: Int
        var height: Int
        var frameIndex: Int
        var usesTransparency: Bool
        var data: [UInt8]
    }

    let width: Int
    let height: Int
    let framesPerSecond: Double
    let palette: GifPalette
    let mapper: GifPixelMapper
    let settings: GifEncodingSettings
    let output: FileHandle

    private var bytes: [UInt8] = []
    private let lzw = GifLzwEncoder()
    private var bytesWritten = 0
    private var writtenFrameCount = 0
    /// Index of every pixel as currently shown.
    private let shown: UnsafeMutablePointer<UInt8>
    /// Index of every pixel in the frame being added, transparent where unchanged.
    private let mapped: UnsafeMutablePointer<UInt8>
    private var currentLab: UnsafeMutablePointer<GifColor>
    private var previousLab: UnsafeMutablePointer<GifColor>
    /// Frame counter value of the last frame that drew each pixel while its colour stood still.
    private let settledAt: UnsafeMutablePointer<Int32>
    private var frameCounter: Int32 = 0
    private let bandCount: Int
    private let bandHeight: Int
    private let bandRects: UnsafeMutablePointer<SIMD4<Int32>>
    private var hasFirstFrame = false
    private var lastFrameIndex = -1
    private var pending: PendingFrame?

    init(width: Int, height: Int, framesPerSecond: Double, palette: GifPalette, settings: GifEncodingSettings, loops: Bool, output: FileHandle) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.palette = palette
        self.settings = settings
        self.output = output
        mapper = GifPixelMapper(palette: palette, table: GifNearestColorTable(palette: palette), dither: settings.dither)

        bytes.append(contentsOf: Array("GIF89a".utf8))
        Self.appendUInt16(width, to: &bytes)
        Self.appendUInt16(height, to: &bytes)
        bytes.append(contentsOf: [0xF7, 0x00, 0x00])
        for i in 0..<256 {
            let color = i < palette.count ? palette.colors[i] : GifPalette.RGB(r: 0, g: 0, b: 0)
            bytes.append(contentsOf: [color.r, color.g, color.b])
        }
        if loops {
            bytes.append(contentsOf: [0x21, 0xFF, 0x0B])
            bytes.append(contentsOf: Array("NETSCAPE2.0".utf8))
            bytes.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        }

        let pixelCount = width * height
        shown = .allocate(capacity: pixelCount)
        mapped = .allocate(capacity: pixelCount)
        currentLab = .allocate(capacity: pixelCount)
        previousLab = .allocate(capacity: pixelCount)
        settledAt = .allocate(capacity: pixelCount)
        settledAt.initialize(repeating: -2, count: pixelCount)
        bandCount = min(max(height, 1), 32)
        bandHeight = (height + bandCount - 1) / bandCount
        bandRects = .allocate(capacity: bandCount)
    }

    deinit {
        shown.deallocate()
        mapped.deallocate()
        currentLab.deallocate()
        previousLab.deallocate()
        settledAt.deallocate()
        bandRects.deallocate()
    }

    static func appendUInt16(_ value: Int, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    /// Adds the frame shown from `frameIndex` (in frames of `framesPerSecond`) on.
    func add(_ pixels: GifFramePixels, frameIndex: Int) throws {
        precondition(pixels.width == width && pixels.height == height)
        precondition(frameIndex > lastFrameIndex)
        lastFrameIndex = frameIndex
        let isFirst = !hasFirstFrame
        swap(&currentLab, &previousLab)
        frameCounter += 1
        guard let rect = mapChangedPixels(pixels, isFirst: isFirst) else { return }
        hasFirstFrame = true

        let left = Int(rect.x), top = Int(rect.z)
        let rectWidth = Int(rect.y) - left + 1
        let rectHeight = Int(rect.w) - top + 1
        var indices = [UInt8](repeating: 0, count: rectWidth * rectHeight)
        for row in 0..<rectHeight {
            for column in 0..<rectWidth {
                indices[row * rectWidth + column] = mapped[(top + row) * width + left + column]
            }
        }
        var data: [UInt8] = []
        data.reserveCapacity(indices.count / 2)

        if settings.lossyDistance <= 0 {
            indices.withUnsafeMutableBufferPointer { lzw.encode($0, tolerance: nil, into: &data) }
        } else {
            let n = indices.count
            let targetLab = UnsafeMutablePointer<GifColor>.allocate(capacity: n)
            let shownLab = UnsafeMutablePointer<GifColor>.allocate(capacity: n)
            let budgetSquared = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer {
                targetLab.deallocate()
                shownLab.deallocate()
                budgetSquared.deallocate()
            }
            computeTolerance(left: left, top: top, rectWidth: rectWidth, rectHeight: rectHeight, isFirst: isFirst,
                             targetLab: targetLab, shownLab: shownLab, budgetSquared: budgetSquared)
            let tolerance = GifLzwTolerance(
                targetLab: targetLab, shownLab: shownLab, paletteLab: palette.oklab,
                budgetSquared: budgetSquared, allowsTransparency: !isFirst
            )
            indices.withUnsafeMutableBufferPointer { lzw.encode($0, tolerance: tolerance, into: &data) }
        }

        for row in 0..<rectHeight {
            for column in 0..<rectWidth {
                let index = indices[row * rectWidth + column]
                guard index != Self.transparentIndex else { continue }
                let p = (top + row) * width + left + column
                shown[p] = index
                if !isFirst && currentLab[p] == previousLab[p] {
                    settledAt[p] = frameCounter
                }
            }
        }

        var usesTransparency = false
        if !isFirst {
            guard indices.contains(where: { $0 != Self.transparentIndex }) else { return }
            usesTransparency = indices.contains(Self.transparentIndex)
        }
        try flushPending(until: frameIndex)
        pending = PendingFrame(left: left, top: top, width: rectWidth, height: rectHeight,
                               frameIndex: frameIndex, usesTransparency: usesTransparency, data: data)
    }

    /// Writes the last frame, shown until `endFrameIndex` (at least one frame), and the trailer.
    func finish(endFrameIndex: Int) throws -> GifEncodingStats {
        try flushPending(until: max(lastFrameIndex + 1, endFrameIndex))
        bytes.append(0x3B)
        try output.write(contentsOf: bytes)
        bytesWritten += bytes.count
        bytes.removeAll(keepingCapacity: true)
        return GifEncodingStats(bytes: bytesWritten, writtenFrameCount: writtenFrameCount)
    }

    private func flushPending(until frameIndex: Int) throws {
        guard let frame = pending else { return }
        pending = nil
        // Delays in centiseconds, from rounded start times so they never drift.
        let end = Int((Double(frameIndex) * 100 / framesPerSecond).rounded())
        let start = Int((Double(frame.frameIndex) * 100 / framesPerSecond).rounded())
        bytes.append(contentsOf: [0x21, 0xF9, 0x04])
        bytes.append((frame.usesTransparency ? 1 : 0) | 4)
        Self.appendUInt16(end - start, to: &bytes)
        bytes.append(contentsOf: [Self.transparentIndex, 0x00, 0x2C])
        Self.appendUInt16(frame.left, to: &bytes)
        Self.appendUInt16(frame.top, to: &bytes)
        Self.appendUInt16(frame.width, to: &bytes)
        Self.appendUInt16(frame.height, to: &bytes)
        bytes.append(0x00)
        bytes.append(contentsOf: frame.data)
        writtenFrameCount += 1
        let chunk = bytes
        bytes.removeAll(keepingCapacity: true)
        try output.write(contentsOf: chunk)
        bytesWritten += chunk.count
    }

    /// Maps every pixel and marks the ones that changed beyond the keep distance. Returns the
    /// changed rectangle as (minX, maxX, minY, maxY), or nil when nothing changed.
    private func mapChangedPixels(_ pixels: GifFramePixels, isFirst: Bool) -> SIMD4<Int32>? {
        let keepSquared = settings.keepDistance * settings.keepDistance
        let width = width, height = height, bandHeight = bandHeight
        let shown = shown, mapped = mapped, currentLab = currentLab, bandRects = bandRects
        let mapper = mapper, paletteLab = palette.oklab
        let bytesPerPixel = pixels.layout.bytesPerPixel
        let redOffset = pixels.layout.redOffset, blueOffset = pixels.layout.blueOffset
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            var rect = SIMD4<Int32>(Int32.max, Int32.min, Int32.max, Int32.min)
            let lower = band * bandHeight
            let upper = min(lower + bandHeight, height)
            if lower < upper {
                for y in lower..<upper {
                    var p = pixels.base + y * pixels.bytesPerRow
                    for x in 0..<width {
                        let r = p[redOffset], g = p[1], b = p[blueOffset]
                        p += bytesPerPixel
                        let lab = GifColorMath.oklab(r, g, b)
                        let i = y * width + x
                        currentLab[i] = lab
                        let index = mapper.map(r, g, b, x: x, y: y, lab: lab)
                        if !isFirst {
                            let before = shown[i]
                            if before == index || !(keepSquared < paletteLab[Int(before)].distanceSquared(to: lab)) {
                                mapped[i] = GifStreamEncoder.transparentIndex
                                continue
                            }
                        }
                        mapped[i] = index
                        let xi = Int32(x), yi = Int32(y)
                        rect.x = rect.x < xi ? rect.x : xi
                        rect.y = rect.y > xi ? rect.y : xi
                        rect.z = rect.z < yi ? rect.z : yi
                        rect.w = rect.w > yi ? rect.w : yi
                    }
                }
            }
            bandRects[band] = rect
        }
        var rect = SIMD4<Int32>(Int32.max, Int32.min, Int32.max, Int32.min)
        for band in 0..<bandCount {
            let b = bandRects[band]
            rect.x = b.x < rect.x ? b.x : rect.x
            rect.y = b.y > rect.y ? b.y : rect.y
            rect.z = b.z < rect.z ? b.z : rect.z
            rect.w = b.w > rect.w ? b.w : rect.w
        }
        return rect.x <= rect.y ? rect : nil
    }

    /// Per pixel of the rectangle: the colour to show, the colour shown now, and the squared error
    /// budget, from the flat budget on flat areas up to the full budget where the local lightness
    /// contrast reaches the texture contrast. A pixel drawn while still on the previous frame and
    /// still unchanged gets at most the keep distance.
    private func computeTolerance(left: Int, top: Int, rectWidth: Int, rectHeight: Int, isFirst: Bool,
                                  targetLab: UnsafeMutablePointer<GifColor>, shownLab: UnsafeMutablePointer<GifColor>,
                                  budgetSquared: UnsafeMutablePointer<Float>) {
        let lossy = settings.lossyDistance
        let flat = lossy < settings.lossyFlatDistance ? lossy : settings.lossyFlatDistance
        let range = lossy - flat
        let texture = settings.lossyTextureContrast
        let keep = settings.keepDistance
        let width = width, height = height
        let currentLab = currentLab, previousLab = previousLab, shown = shown, settledAt = settledAt
        let paletteLab = palette.oklab
        let previousCounter = frameCounter - 1
        let chunks = min(rectHeight, 32)
        let rowsPerChunk = (rectHeight + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * rowsPerChunk
            let upper = min(lower + rowsPerChunk, rectHeight)
            guard lower < upper else { return }
            for row in lower..<upper {
                let y = top + row
                let rowStart = y * width + left
                (targetLab + row * rectWidth).update(from: currentLab + rowStart, count: rectWidth)
                for column in 0..<rectWidth {
                    let p = rowStart + column
                    let i = row * rectWidth + column
                    shownLab[i] = paletteLab[Int(shown[p])]
                    let c = currentLab[p].x
                    let l = left + column > 0 ? currentLab[p - 1].x : c
                    let r = left + column + 1 < width ? currentLab[p + 1].x : c
                    let u = y > 0 ? currentLab[p - width].x : c
                    let d = y + 1 < height ? currentLab[p + width].x : c
                    var hMax = c <= l ? l : c
                    hMax = hMax <= r ? r : hMax
                    var vMax = c <= u ? u : c
                    vMax = vMax <= d ? d : vMax
                    var hMin = l < c ? l : c
                    hMin = r < hMin ? r : hMin
                    var vMin = u < c ? u : c
                    vMin = d < vMin ? d : vMin
                    let hRange = hMax - hMin, vRange = vMax - vMin
                    let contrast = hRange <= vRange ? hRange : vRange
                    let ratio = contrast / texture
                    var budget = flat + (ratio < 1 ? range * ratio : range)
                    if !isFirst && settledAt[p] == previousCounter && currentLab[p] == previousLab[p] {
                        budget = budget <= keep ? budget : keep
                    }
                    budgetSquared[i] = budget * budget
                }
            }
        }
    }
}
