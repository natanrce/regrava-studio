@testable import RegravaCapture
import XCTest

final class MicrophoneLidTests: XCTestCase {
    func testLidClosedModels() {
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: nil))
        XCTAssertTrue(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBookAir8,1"))
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBookAir7,2"))
        XCTAssertTrue(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBookPro15,1"))
        XCTAssertTrue(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBookPro18,3"))
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBookPro14,3"))
        XCTAssertTrue(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBookPro"))
        XCTAssertTrue(MicrophoneLid.isT2MacBook(modelIdentifier: "Mac14,2"))
        XCTAssertTrue(MicrophoneLid.isT2MacBook(modelIdentifier: "Mac16,1"))
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: "Mac14,3"))
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: "Mac13,1"))
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: "MacBook10,1"))
        XCTAssertFalse(MicrophoneLid.isT2MacBook(modelIdentifier: "Mac99,1"))
        XCTAssertFalse(MicrophoneLid.mayHaveLidClosed(microphoneID: "SomeUSBMic"))
    }
}
