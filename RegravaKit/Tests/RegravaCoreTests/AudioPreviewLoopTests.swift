import XCTest
@testable import RegravaCore

final class AudioPreviewLoopTests: XCTestCase {
    func testStartsAtPlayheadInsideRange() {
        let loop = AudioPreviewLoop(timeMs: 1500, changedStartMs: 1000, changedEndMs: 10_000)
        XCTAssertEqual(loop.startFrame, 72_000)
        XCTAssertEqual(loop.endFrame, 168_000)
    }

    func testPlayheadOutsideStartsAtRangeStart() {
        let loop = AudioPreviewLoop(timeMs: 20_000, changedStartMs: 1000, changedEndMs: 10_000)
        XCTAssertEqual(loop.startMs, 1000)
        XCTAssertEqual(loop.endMs, 3000)
    }

    func testNearTheEndKeepsHalfASecond() {
        let loop = AudioPreviewLoop(timeMs: 9900, changedStartMs: 1000, changedEndMs: 10_000)
        XCTAssertEqual(loop.startMs, 9500)
        XCTAssertEqual(loop.endMs, 10_000)
    }

    func testShortRangeStillLoopsHalfASecond() {
        let loop = AudioPreviewLoop(timeMs: 100, changedStartMs: 0, changedEndMs: 300)
        XCTAssertEqual(loop.startMs, 0)
        XCTAssertEqual(loop.endMs, 500)
    }
}
