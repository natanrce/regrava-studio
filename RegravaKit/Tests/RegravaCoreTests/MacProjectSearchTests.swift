import XCTest
@testable import RegravaCore

final class MacProjectSearchTests: XCTestCase {
    func testPatternWrapsTheTermInWildcards() {
        XCTAssertEqual(MacProjectSearch.namePattern(term: "zqxa Alpha", fileExtension: "screenstudio"), "*zqxa Alpha*.screenstudio")
        XCTAssertEqual(MacProjectSearch.namePattern(term: "Café"), "*Café*.regrava")
        XCTAssertEqual(MacProjectSearch.namePattern(term: "a\"b", fileExtension: "screenstudio"), "*a\"b*.screenstudio")
    }

    func testPatternDropsWildcardsAndBackslashesThenTrims() {
        XCTAssertEqual(MacProjectSearch.namePattern(term: "zq*x?a\\b", fileExtension: "screenstudio"), "*zqxab*.screenstudio")
        XCTAssertEqual(MacProjectSearch.namePattern(term: "* zqxa alpha", fileExtension: "screenstudio"), "*zqxa alpha*.screenstudio")
        XCTAssertEqual(MacProjectSearch.namePattern(term: "zqxa alpha *", fileExtension: "screenstudio"), "*zqxa alpha*.screenstudio")
        XCTAssertEqual(MacProjectSearch.namePattern(term: "  Ölberg  ", fileExtension: "screenstudio"), "*Ölberg*.screenstudio")
        // Inner spacing is kept as typed.
        XCTAssertEqual(MacProjectSearch.namePattern(term: "zqxa  Alpha"), "*zqxa  Alpha*.regrava")
    }

    func testPatternWithNothingLeftMatchesEveryProject() {
        XCTAssertEqual(MacProjectSearch.namePattern(term: "*", fileExtension: "screenstudio"), "*.screenstudio")
        XCTAssertEqual(MacProjectSearch.namePattern(term: ""), "*.regrava")
    }

    func testLimit() {
        XCTAssertEqual(MacProjectSearch.limit, 250)
    }

    func testNameRemovesOnlyTheExactExtension() {
        XCTAssertEqual(MacProjectSearch.projectName(path: "/Users/me/Projects/zqxa Alpha.regrava"), "zqxa Alpha")
        XCTAssertEqual(MacProjectSearch.projectName(path: "/Users/me/zqxa Upper.REGRAVA"), "zqxa Upper.REGRAVA")
        XCTAssertEqual(MacProjectSearch.projectName(path: "/Users/me/v1.2 demo.regrava"), "v1.2 demo")
        XCTAssertEqual(MacProjectSearch.projectName(path: "/Users/me/.regrava"), ".regrava")
    }

    func testLocationIsTheParentFolderWithHomeAsTilde() {
        XCTAssertEqual(MacProjectSearch.location(path: "/Users/natan/regrava-search-fixture/sub/zqxa Bravo.regrava"), "~/regrava-search-fixture/sub")
        XCTAssertEqual(MacProjectSearch.location(path: "/Users/natan/zqxa.regrava"), "~")
        XCTAssertEqual(MacProjectSearch.location(path: "/Volumes/Disk/Work/zqxa.regrava"), "/Volumes/Disk/Work")
        XCTAssertEqual(MacProjectSearch.location(path: "/zqxa.regrava"), "")
    }

    func testFoundLabel() {
        XCTAssertEqual(MacProjectSearch.foundLabel(count: 0), "0 projects found")
        XCTAssertEqual(MacProjectSearch.foundLabel(count: 1), "1 project found")
        XCTAssertEqual(MacProjectSearch.foundLabel(count: 250), "250 projects found")
    }
}
