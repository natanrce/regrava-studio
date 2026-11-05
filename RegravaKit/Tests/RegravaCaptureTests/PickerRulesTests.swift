import CoreGraphics
@testable import RegravaCapture
import XCTest

final class PickerRulesTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testOverlapNeedsSeventyPercentOfTheSmallerRect() {
        // A window fully on the display.
        XCTAssertTrue(PickerRules.overlaps(CGRect(x: 100, y: 100, width: 800, height: 600), display, ratio: 0.7))
        // 75% of a 400×400 area on the display.
        XCTAssertTrue(PickerRules.overlaps(CGRect(x: 1212, y: 0, width: 400, height: 400), display, ratio: 0.7))
        // 50% of it.
        XCTAssertFalse(PickerRules.overlaps(CGRect(x: 1312, y: 0, width: 400, height: 400), display, ratio: 0.7))
        // Exactly 70%, and just under.
        XCTAssertFalse(PickerRules.overlaps(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 31, y: 0, width: 200, height: 200), ratio: 0.7))
        XCTAssertTrue(PickerRules.overlaps(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 30, y: 0, width: 200, height: 200), ratio: 0.7))
        // On another display.
        XCTAssertFalse(PickerRules.overlaps(CGRect(x: 1600, y: 0, width: 400, height: 400), display, ratio: 0.7))
    }

    func testArrowChangesThatLeaveTheDisplayAreRejected() {
        let size = display.size
        let area = CGRect(x: 0, y: 10, width: 300, height: 200)
        XCTAssertNil(PickerRules.arrowChange(area, dx: -1, dy: 0, resize: false, display: size))
        XCTAssertEqual(PickerRules.arrowChange(area, dx: 10, dy: 0, resize: false, display: size), CGRect(x: 10, y: 10, width: 300, height: 200))
        let atEdge = CGRect(x: 1212, y: 0, width: 300, height: 200)
        XCTAssertNil(PickerRules.arrowChange(atEdge, dx: 1, dy: 0, resize: true, display: size))
        XCTAssertEqual(PickerRules.arrowChange(atEdge, dx: -10, dy: 1, resize: true, display: size), CGRect(x: 1212, y: 0, width: 290, height: 201))
        XCTAssertNil(PickerRules.arrowChange(CGRect(x: 5, y: 5, width: 0, height: 10), dx: -1, dy: 0, resize: true, display: size))
    }

    func testIgnoreSuggestionOnlyForDisplaySizedWindows() {
        XCTAssertTrue(PickerRules.isFullscreen(window: CGRect(x: 0, y: 0, width: 1512, height: 982), display: display))
        XCTAssertFalse(PickerRules.isFullscreen(window: CGRect(x: 0, y: 38, width: 1512, height: 944), display: display))
    }

    func testWindowSizePresets() {
        XCTAssertEqual(WindowSizePresets.all.count, 25)
        XCTAssertEqual(WindowSizePresets.sixteenByNine.map(\.label), ["1280 × 720", "1920 × 1080", "2560 × 1440"])
        let current = PickerSize(width: 1280, height: 720)
        XCTAssertFalse(WindowSizePresets.isEnabled(current, current: current, display: display.size))
        XCTAssertFalse(WindowSizePresets.isEnabled(PickerSize(width: 1920, height: 1080), current: current, display: display.size))
        XCTAssertTrue(WindowSizePresets.isEnabled(PickerSize(width: 1024, height: 768), current: current, display: display.size))
        XCTAssertFalse(WindowSizePresets.canSave(current, saved: []))
        XCTAssertTrue(WindowSizePresets.canSave(PickerSize(width: 1000, height: 700), saved: []))
        XCTAssertFalse(WindowSizePresets.canSave(PickerSize(width: 1000, height: 700), saved: [PickerSize(width: 1000, height: 700)]))
    }

    func testAreaFieldsAreFittedOntoTheDisplay() {
        let size = display.size
        let crop = CGRect(x: 1000, y: 500, width: 400, height: 300)
        XCTAssertEqual(AreaCrop.fit(width: 600, crop: crop, display: size), CGRect(x: 912, y: 500, width: 600, height: 300))
        XCTAssertEqual(AreaCrop.fit(height: 2000, crop: crop, display: size), CGRect(x: 1000, y: 0, width: 400, height: 982))
        XCTAssertEqual(AreaCrop.fit(x: 20, crop: crop, display: size), CGRect(x: 20, y: 500, width: 400, height: 300))
    }

    func testAspectRatioChoiceKeepsTheHeight() {
        let size = display.size
        let crop = CGRect(x: 100, y: 100, width: 400, height: 300)
        // 16:9 from a 300 tall area: 533.3 × 300.
        let wide = AreaCrop.constrain(crop: crop, aspectRatio: 16.0 / 9, display: size, minimumSize: 200)
        XCTAssertEqual(wide.width, 300 * 16 / 9, accuracy: 0.001)
        XCTAssertEqual(wide.height, 300)
        XCTAssertEqual(wide.origin, CGPoint(x: 100, y: 100))
        // A tall area at 16:9 is limited to the widest 16:9 area of the display (1512 × 850.5).
        let tall = AreaCrop.constrain(crop: CGRect(x: 0, y: 0, width: 300, height: 900), aspectRatio: 16.0 / 9, display: size, minimumSize: 200)
        XCTAssertEqual(tall.width, 1512, accuracy: 0.001)
        XCTAssertEqual(tall.height, 850.5, accuracy: 0.001)
        // Typing a width under 1:1 sets the height, raised to the minimum.
        let square = AreaCrop.constrain(width: 0.5, crop: crop, aspectRatio: 1, display: size, minimumSize: 1)
        XCTAssertEqual(square.size, CGSize(width: 1, height: 1))
    }

    func testSavedAreaRules() {
        let size = display.size
        XCTAssertTrue(AreaCrop.isSavedEnabled(CGRect(x: 10, y: 10, width: 800, height: 600), current: CGSize(width: 400, height: 300), display: size))
        XCTAssertFalse(AreaCrop.isSavedEnabled(CGRect(x: 1000, y: 10, width: 800, height: 600), current: CGSize(width: 400, height: 300), display: size))
        XCTAssertFalse(AreaCrop.isSavedEnabled(CGRect(x: 10, y: 10, width: 400, height: 300), current: CGSize(width: 400, height: 300), display: size))
    }
}
