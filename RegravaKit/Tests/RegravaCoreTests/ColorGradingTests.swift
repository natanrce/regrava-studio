import Foundation
import Testing
@testable import RegravaCore

struct ColorGradingTests {
    @Test func skinCenterHueIsFixed() {
        #expect(abs(ColorGrading.skinCenterHueDeg - 62.09312537998183) < 1e-6)
    }

    @Test func toneCurveTangentsMatchReference() {
        let studio = ColorGrading.builtInLooks[0].toneCurve!
        let expected = [0.75, 0.956081, 1.064414, 0.858333, 0.75]
        for (a, b) in zip(ColorGrading.toneCurveTangents(studio), expected) { #expect(abs(a - b) < 1e-5) }
        let film = ColorGrading.builtInLooks[2].toneCurve!
        for (a, b) in zip(ColorGrading.toneCurveTangents(film), [0.5, 0.782609, 1.157609, 1.046875, 0.671875, 0.5]) { #expect(abs(a - b) < 1e-5) }
    }

    @Test func whiteBalanceGainsMatchReference() {
        let golden = ColorGrading.settings(ColorGrading.builtInLooks[3])
        #expect(abs(golden.whiteBalanceGains.0 - 1.0536) < 1e-9 && abs(golden.whiteBalanceGains.1 - 1.0048) < 1e-9 && abs(golden.whiteBalanceGains.2 - 0.9416) < 1e-9)
    }

    @Test func monoIsGrayAndLooksKeepBlackAndWhiteNearby() throws {
        let mono = ColorGrading.lut(for: ColorGrading.builtInLooks.last!)
        #expect(mono.size == 33 && mono.texels.count == 33 * 33 * 33 * 4)
        // A saturated red becomes a gray with a hint of warm paper tone.
        let i = (0 * 33 + 0) * 33 + 32
        let r = Int(mono.texels[i * 4]), g = Int(mono.texels[i * 4 + 1]), b = Int(mono.texels[i * 4 + 2])
        #expect(abs(r - g) <= 12 && abs(g - b) <= 12 && r >= b, "\(r) \(g) \(b)")
        let studio = ColorGrading.lut(for: ColorGrading.builtInLooks[0])
        #expect(studio.texels[0] < 8 && studio.texels[(33 * 33 * 33 - 1) * 4] > 245)
    }

    @Test func cubeRoundTripsLosslessly() throws {
        let lut = ColorGrading.lut(for: ColorGrading.builtInLooks[1])
        let text = lut.cube(title: "Cinema", comments: ["a", "b"])
        #expect(text.hasPrefix("TITLE \"Cinema\"\n# a\n# b\n\nLUT_3D_SIZE 33\n\n"))
        #expect(try ColorLUT(cube: text) == lut)
        #expect(throws: ColorLUT.ParseError.oneDimensional) { try ColorLUT(cube: "LUT_1D_SIZE 4") }
    }

    @Test func assetDisplayNameDropsTheSuffix() {
        #expect(ColorGrading.displayName(ofAsset: "Studio-a1B2c3D4e5.cube") == "Studio")
        #expect(ColorGrading.displayName(ofAsset: "Studio.cube") == "Studio.cube")
    }
}
