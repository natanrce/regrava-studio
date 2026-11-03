import XCTest
@testable import RegravaCore

final class BackgroundPaletteTests: XCTestCase {
    /// A repeatable 0..<1 sequence (32-bit LCG).
    private func seeded(_ seed: UInt32) -> BackgroundPalette.Random {
        var x = seed
        return {
            x = x &* 1664525 &+ 1013904223
            return Double(x) / 4294967296
        }
    }

    func testMaxChroma() {
        XCTAssertEqual(OKLCHColor.maxChroma(lightness01: 0.7, hueDegrees: 30), 0.21684770584106447, accuracy: 1e-12)
        XCTAssertEqual(OKLCHColor.maxChroma(lightness01: 0.4, hueDegrees: 140), 0.15589435100555424, accuracy: 1e-12)
        XCTAssertEqual(OKLCHColor.maxChroma(lightness01: 0.9, hueDegrees: 250), 0.07254114151000976, accuracy: 1e-12)
    }

    func testGamutMappedHex() {
        XCTAssertEqual(OKLCHColor.rgba(OKLCH(lightness01: 0.65, chroma: 0.3, hueDegrees: 200)).hexString, "#00a6ae")
    }

    func testGradientHueRotation() {
        let gradient = BackgroundGradient(colors: [RGBA(hex: 0x4776E6), RGBA(hex: 0x8E54E9)])
        XCTAssertEqual(gradient.hueDegrees, 264.4798277534835, accuracy: 1e-9)
        XCTAssertEqual(gradient.withHue(10).stops.map(\.color.hexString), ["#d33f64", "#c45826"])
    }

    func testRandomPalettes() {
        let expected: [(UInt32, [String], [String])] = [
            (1, ["#5c5547", "#e5ddc1"], ["#8f2f89"]),
            (42, ["#003128", "#0d4756", "#1038e2"], ["#decfb5"]),
            (7, ["#859ba2", "#e4f1f3"], ["#6f9200"]),
        ]
        for (seed, gradient, single) in expected {
            let random = seeded(seed)
            let count = BackgroundPalette.randomColorCount(random)
            XCTAssertEqual(BackgroundPalette.colors(count, random: random).map(\.hexString), gradient, "seed \(seed)")
            XCTAssertEqual(BackgroundPalette.colors(1, random: seeded(seed + 100)).map(\.hexString), single, "seed \(seed)")
        }
    }
}
