import Foundation

/// What the lossy LZW search may trade for longer matches: a pixel may take any colour within its
/// budget of the colour it should show.
struct GifLzwTolerance {
    /// OkLab colour each pixel should show.
    let targetLab: UnsafePointer<GifColor>
    /// OkLab colour already shown under each pixel (what a transparent pixel would show).
    let shownLab: UnsafePointer<GifColor>
    let paletteLab: UnsafePointer<GifColor>
    /// Largest accepted squared OkLab distance per pixel.
    let budgetSquared: UnsafePointer<Float>
    /// Whether a pixel may become transparent (never on the first frame).
    let allowsTransparency: Bool
}

/// Packs variable-width codes into 255-byte GIF data sub-blocks.
struct GifCodeWriter {
    var bits: UInt64 = 0
    var bitCount = 0
    var block = [UInt8](repeating: 0, count: 255)
    var blockCount = 0

    mutating func write(_ code: Int, size: Int, into out: inout [UInt8]) {
        bits |= UInt64(code) << UInt64(bitCount)
        bitCount += size
        while bitCount >= 8 {
            block[blockCount] = UInt8(truncatingIfNeeded: bits)
            blockCount += 1
            bits >>= 8
            bitCount -= 8
            if blockCount == 255 {
                out.append(255)
                out.append(contentsOf: block[0..<255])
                blockCount = 0
            }
        }
    }

    private mutating func flushBlock(into out: inout [UInt8]) {
        guard blockCount > 0 else { return }
        out.append(UInt8(blockCount))
        out.append(contentsOf: block[0..<blockCount])
        blockCount = 0
    }

    /// Writes the partial byte, the last sub-block and the block terminator.
    mutating func finish(into out: inout [UInt8]) {
        if bitCount > 0 {
            block[blockCount] = UInt8(truncatingIfNeeded: bits)
            blockCount += 1
            bits = 0
            bitCount = 0
            if blockCount == 255 { flushBlock(into: &out) }
        }
        flushBlock(into: &out)
        out.append(0)
    }
}

/// GIF LZW for 8-bit indices. With a tolerance, a pixel that would end the current string may
/// instead take the colour of an existing child string when that colour is within the pixel's
/// budget; the pixel is rewritten to the colour emitted.
final class GifLzwEncoder {
    static let clearCode = 256
    static let endCode = 257

    private var keys = [Int32](repeating: -1, count: 8192)
    private var codes = [Int16](repeating: 0, count: 8192)
    private var firstChild = [Int16](repeating: -1, count: 4096)
    private var nextSibling = [Int16](repeating: -1, count: 4096)
    private var suffix = [UInt8](repeating: 0, count: 4096)

    func encode(_ pixels: UnsafeMutableBufferPointer<UInt8>, tolerance: GifLzwTolerance?, into out: inout [UInt8]) {
        out.append(8)
        var writer = GifCodeWriter()
        writer.write(Self.clearCode, size: 9, into: &out)
        let count = pixels.count
        guard count >= 1 else {
            writer.write(Self.endCode, size: 9, into: &out)
            writer.finish(into: &out)
            return
        }
        for i in keys.indices { keys[i] = -1 }
        for i in firstChild.indices { firstChild[i] = -1 }

        var nextCode = 258
        var codeSize = 9
        var prefix = Int(pixels[0])
        var i = 1
        keys.withUnsafeMutableBufferPointer { keys in
        codes.withUnsafeMutableBufferPointer { codes in
        firstChild.withUnsafeMutableBufferPointer { firstChild in
        nextSibling.withUnsafeMutableBufferPointer { nextSibling in
        suffix.withUnsafeMutableBufferPointer { suffix in
            while i < count {
                let c = pixels[i]
                let key = Int32(c) | Int32(prefix) << 8
                var slot = Int((UInt32(bitPattern: key) &* 0x9E37_79B1) >> 19)
                var matched = false
                while keys[slot] != -1 {
                    if keys[slot] == key {
                        let code = codes[slot]
                        if code >= 0 {
                            prefix = Int(code)
                            matched = true
                        }
                        break
                    }
                    slot = (slot + 1) & 0x1FFF
                }
                if matched {
                    i += 1
                    continue
                }

                if let tolerance, firstChild[prefix] >= 0 {
                    var best = Float.greatestFiniteMagnitude
                    var bestChild = -1
                    var child = Int(firstChild[prefix])
                    while true {
                        let s = suffix[child]
                        var candidate: GifColor?
                        if s == 0xFF {
                            if tolerance.allowsTransparency { candidate = tolerance.shownLab[i] }
                        } else if c != 0xFF {
                            candidate = tolerance.paletteLab[Int(s)]
                        }
                        if let candidate {
                            let d = candidate.distanceSquared(to: tolerance.targetLab[i])
                            if d <= tolerance.budgetSquared[i] {
                                if d <= best {
                                    best = d
                                    bestChild = child
                                }
                            } else if best == .infinity {
                                bestChild = child
                            }
                        } else if best == .infinity {
                            bestChild = child
                        }
                        let next = nextSibling[child]
                        if next < 0 { break }
                        child = Int(next)
                    }
                    if bestChild >= 0 {
                        pixels[i] = suffix[bestChild]
                        prefix = bestChild
                        i += 1
                        continue
                    }
                }

                writer.write(prefix, size: codeSize, into: &out)
                if 1 << codeSize <= nextCode && codeSize < 12 { codeSize += 1 }
                if nextCode >= 4095 {
                    writer.write(Self.clearCode, size: codeSize, into: &out)
                    for k in 0..<keys.count { keys[k] = -1 }
                    for k in 0..<256 { firstChild[k] = -1 }
                    codeSize = 9
                    nextCode = 258
                } else {
                    keys[slot] = key
                    codes[slot] = Int16(nextCode)
                    suffix[nextCode] = c
                    firstChild[nextCode] = -1
                    nextSibling[nextCode] = firstChild[prefix]
                    firstChild[prefix] = Int16(nextCode)
                    nextCode += 1
                }
                prefix = Int(c)
                i += 1
            }
        }
        }
        }
        }
        }
        writer.write(prefix, size: codeSize, into: &out)
        if 1 << codeSize <= nextCode && codeSize < 12 { codeSize += 1 }
        writer.write(Self.endCode, size: codeSize, into: &out)
        writer.finish(into: &out)
    }
}
