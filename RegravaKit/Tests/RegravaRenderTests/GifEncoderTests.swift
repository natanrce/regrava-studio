import CryptoKit
import Foundation
import RegravaCore
import Testing
@testable import RegravaRender

struct GifEncoderTests {
    /// Six 96x64 frames: gradients, a moving square, and frame 3 repeating frame 2.
    private static func frame(_ f: Int, width: Int, height: Int) -> [UInt8] {
        let source = f == 3 ? 2 : f
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = (x * 255 / (width - 1) + source * 9) & 255
                var g = y * 255 / (height - 1)
                var b = ((x * 7 + y * 13 + source * 5) % 97) * 2
                if x >= 8 + source * 10, x < 24 + source * 10, y >= 20, y < 36 { r = 240; g = 32 + source * 20; b = 64 }
                let i = (y * width + x) * 4
                bytes[i] = UInt8(b)
                bytes[i + 1] = UInt8(g)
                bytes[i + 2] = UInt8(r)
            }
        }
        return bytes
    }

    private static func encode(_ settings: GifEncodingSettings) throws -> (Data, GifEncodingStats, GifPalette) {
        let width = 96, height = 64
        let frames = (0..<6).map { frame($0, width: width, height: height) }
        func withPixels<T>(_ index: Int, _ body: (GifFramePixels) throws -> T) rethrows -> T {
            try frames[index].withUnsafeBufferPointer {
                try body(GifFramePixels(base: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4, layout: .bgra))
            }
        }
        let sampler = GifPaletteSampler(pixelStride: 2)
        for i in frames.indices { withPixels(i) { sampler.add($0) } }
        let palette = sampler.makePalette(maxColors: settings.maxColors)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gif-encoder-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let encoder = GifStreamEncoder(width: width, height: height, framesPerSecond: 10, palette: palette,
                                       settings: settings, loops: true, output: handle)
        for i in frames.indices { try withPixels(i) { try encoder.add($0, frameIndex: i) } }
        let stats = try encoder.finish(endFrameIndex: frames.count)
        try handle.close()
        return (try Data(contentsOf: url), stats, palette)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Golden output: any change to the palette, dithering, change detection or LZW shows here.
    @Test func balancedMatchesGoldenBytes() throws {
        let (data, stats, palette) = try Self.encode(.balanced)
        #expect(stats == GifEncodingStats(bytes: 18729, writtenFrameCount: 6))
        #expect(data.count == 18729)
        #expect(Self.sha256(data) == "3058ab72c9f268bcbcd32dc08043d75e9eb8ea14ccf86551c7a031a85d625267")
        #expect(palette.count <= 255)
    }

    @Test func highMatchesGoldenBytes() throws {
        let (data, stats, _) = try Self.encode(.high)
        #expect(stats == GifEncodingStats(bytes: 22280, writtenFrameCount: 6))
        #expect(Self.sha256(data) == "dc42eb333bcc6d54f450a12cf382974cbf1c1733afce99b2932d9b7ef51d4d06")
    }

    @Test func settingsPerMode() {
        let balanced = GifEncodingSettings.forMode(ExportQuality.socialMedia.gifMode)
        #expect(balanced.keepDistance == 0.015 && balanced.lossyDistance == 0.15)
        #expect(balanced.lossyFlatDistance == 0.025 && balanced.lossyTextureContrast == 0.08)
        let high = GifEncodingSettings.forMode(ExportQuality.studio.gifMode)
        #expect(high.keepDistance == 0.01 && high.lossyDistance == 0.1)
        #expect(high.lossyFlatDistance == 0.015 && high.lossyTextureContrast == 0.08)
        for settings in [balanced, high] {
            #expect(settings.dither.exactDistance == 0.004 && settings.dither.maxSpread == 0.2 && settings.dither.strength == 1)
            #expect(settings.maxColors == 255)
        }
    }

    @Test func blueNoiseMatchesGoldenThresholds() {
        let t = GifBlueNoise.thresholds
        let expected: [(Int, UInt32)] = [(0, 0x3D7C_8000), (1, 0x3F7E_4800), (63, 0x3EC1_B000), (64, 0x3F44_D800), (2048, 0x3E80_7000), (4095, 0x3E42_6000)]
        for (index, bits) in expected { #expect(t[index].bitPattern == bits) }
        let data = Data(bytes: t, count: 4096 * MemoryLayout<Float>.size)
        #expect(Self.sha256(data) == "16993b1b5bedc4e5414fe87349459e82b7d777cc1de4287ee19c7548924978bd")
        // Every rank appears once.
        let ranks = Set((0..<4096).map { Int(t[$0] * 4096 - 0.5) })
        #expect(ranks.count == 4096)
    }

    @Test func lzwWithoutToleranceDecodesBack() {
        var pixels: [UInt8] = (0..<5000).map { (i: Int) -> UInt8 in UInt8((i * 31 + i / 7) % 200) }
        let input = pixels
        var data: [UInt8] = []
        pixels.withUnsafeMutableBufferPointer { GifLzwEncoder().encode($0, tolerance: nil, into: &data) }
        #expect(pixels == input)
        #expect(Self.decodeLzw(data) == input)
    }

    @Test func emptyLzwIsClearThenEnd() {
        var data: [UInt8] = []
        GifLzwEncoder().encode(UnsafeMutableBufferPointer(start: nil, count: 0), tolerance: nil, into: &data)
        #expect(data == [8, 3, 0x00, 0x03, 0x02, 0])
    }

    /// Plain GIF LZW decoder for 8-bit data.
    private static func decodeLzw(_ data: [UInt8]) -> [UInt8] {
        var stream: [UInt8] = []
        var position = 1
        while data[position] != 0 {
            let length = Int(data[position])
            stream += data[(position + 1)...(position + length)]
            position += length + 1
        }
        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] } + [[], []]
        var size = 9, bit = 0
        var previous: [UInt8]?
        var out: [UInt8] = []
        while bit + size <= stream.count * 8 {
            var code = 0
            for k in 0..<size where stream[(bit + k) / 8] >> ((bit + k) % 8) & 1 == 1 { code |= 1 << k }
            bit += size
            if code == 256 { table = Array(table[0..<258]); size = 9; previous = nil; continue }
            if code == 257 { break }
            let entry: [UInt8]
            if code < table.count { entry = table[code] } else { entry = previous! + [previous![0]] }
            out += entry
            if let previous {
                table.append(previous + [entry[0]])
                if table.count == 1 << size && size < 12 { size += 1 }
            }
            previous = entry
        }
        return out
    }
}
