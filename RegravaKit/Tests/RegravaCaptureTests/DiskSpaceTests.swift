import Foundation
@testable import RegravaCapture
import XCTest

final class DiskSpaceTests: XCTestCase {
    func testLowDiskThreshold() {
        let gb = DiskSpace.minimumFreeBytes
        XCTAssertEqual(gb, 1_073_741_824)
        XCTAssertFalse(DiskSpace.shouldStopRecording(freeBytes: [nil, nil]))
        XCTAssertFalse(DiskSpace.shouldStopRecording(freeBytes: [gb, 5 * gb]))
        XCTAssertTrue(DiskSpace.shouldStopRecording(freeBytes: [5 * gb, gb - 1]))
        XCTAssertTrue(DiskSpace.shouldStopRecording(freeBytes: [nil, 0]))
        XCTAssertNotNil(DiskSpace.freeBytes(at: URL(fileURLWithPath: NSTemporaryDirectory())))
        XCTAssertNil(DiskSpace.freeBytes(at: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }
}
