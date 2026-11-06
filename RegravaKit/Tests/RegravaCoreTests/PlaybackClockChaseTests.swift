import XCTest
@testable import RegravaCore

final class PlaybackClockChaseTests: XCTestCase {
    func testCatchesUpAFifthOfTheError() {
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: 10, deltaMs: 16), 2, accuracy: 1e-12)
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: -5, deltaMs: 16), -1, accuracy: 1e-12)
    }

    func testCatchUpIsAtMostHalfATick() {
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: 200, deltaMs: 16), 8)
    }

    func testWaitsWhenAWholeTickAhead() {
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: -16, deltaMs: 16), -16)
        XCTAssertEqual(PlaybackClockChase.playerRate(rate: 1, deltaMs: 16, errorMs: -40), 0)
    }

    func testIgnoresHugeOrMissingErrors() {
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: 1001, deltaMs: 16), 0)
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: .nan, deltaMs: 16), 0)
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: 10, deltaMs: 0), 0)
    }

    func testReverseIsMirrored() {
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: -10, deltaMs: -16), -2, accuracy: 1e-12)
        XCTAssertEqual(PlaybackClockChase.correction(errorMs: 16, deltaMs: -16), 16)
        XCTAssertEqual(PlaybackClockChase.playerRate(rate: -2, deltaMs: -32, errorMs: -10), -2 * (32 + 2) / 32.0, accuracy: 1e-12)
    }

    func testPlayerRateSpeedsUpBehind() {
        XCTAssertEqual(PlaybackClockChase.playerRate(rate: 1, deltaMs: 16, errorMs: 10), 18.0 / 16, accuracy: 1e-12)
    }
}
