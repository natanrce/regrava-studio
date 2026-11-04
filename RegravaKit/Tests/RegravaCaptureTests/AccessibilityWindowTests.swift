import CoreGraphics
@testable import RegravaCapture
import XCTest

final class AccessibilityWindowTests: XCTestCase {
    func testAccessibilityWindowMatchScore() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertEqual(AccessibilityWindow.matchScore(axTitle: "Doc", axFrame: frame, title: "Doc", frame: frame), 5)
        XCTAssertEqual(AccessibilityWindow.matchScore(axTitle: "Doc — Edited", axFrame: nil, title: "Doc", frame: frame), 2)
        XCTAssertEqual(AccessibilityWindow.matchScore(axTitle: "Other", axFrame: frame.offsetBy(dx: 4, dy: -4), title: "", frame: frame), 2)
        XCTAssertEqual(AccessibilityWindow.matchScore(axTitle: "Other", axFrame: CGRect(x: 100, y: 50, width: 300, height: 200), title: "Doc", frame: frame), 1)
        XCTAssertEqual(AccessibilityWindow.matchScore(axTitle: "Other", axFrame: frame.offsetBy(dx: 5, dy: 0), title: "Doc", frame: frame), 0)
    }

    func testCornerRadiusRules() {
        func radius(_ subrole: String?, _ children: [(String?, CGFloat?)]) -> Double {
            AccessibilityWindow.cornerRadius(subrole: subrole, childRoles: children.map { child in (role: child.0, height: { child.1 }) })
        }
        XCTAssertEqual(radius("AXDialog", [("AXToolbar", 52)]), 16)
        XCTAssertEqual(radius("AXSheet", []), 16)
        XCTAssertEqual(radius("AXFullScreen", [("AXToolbar", 52)]), 0)
        XCTAssertEqual(radius("AXStandardWindow", [("AXButton", 20), ("AXToolbar", 52)]), 26)
        XCTAssertEqual(radius("AXStandardWindow", [("AXToolbar", 50)]), 20)
        XCTAssertEqual(radius("AXStandardWindow", [("AXToolbar", nil)]), 26)
        XCTAssertEqual(radius(nil, [("AXGroup", 40)]), 16)
    }
}
