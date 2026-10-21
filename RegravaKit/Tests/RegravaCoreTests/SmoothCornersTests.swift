import Testing
@testable import RegravaCore

@Suite struct SmoothCornersTests {
    @Test func fullSmoothingMatchesReferenceTable() {
        let expected = [1.00000, 1.00136, 1.00544, 1.01221, 1.02169, 1.03387, 1.04871, 1.06614,
                        1.08595, 1.10776, 1.13082, 1.15389, 1.17519, 1.19242, 1.20344, 1.20711]
        let lut = SmoothCorners.lut(width: 1600, height: 900, radius: 16)
        for (a, b) in zip(lut, expected) { #expect(abs(a - b) < 0.0005, "\(lut)") }
        #expect(SmoothCorners.extent(width: 1600, height: 900, radius: 16, smoothing: 1) == 32)
    }

    @Test func noSmoothingIsACircle() {
        #expect(SmoothCorners.lut(width: 100, height: 100, radius: 10, smoothing: 0).allSatisfy { $0 == 1 })
        // A pill (radius = half the side) keeps a circular cap.
        let pill = SmoothCorners.lut(width: 200, height: 100, radius: 50)
        #expect(abs(pill[15] - 1) < 0.01, "\(pill)")
    }
}
