import XCTest
@testable import RegravaCore

final class CommandSearchTests: XCTestCase {
    func testScoreOfExactAndPrefixMatches() {
        XCTAssertEqual(CommandScore.score("hello", "hello"), 1)
        XCTAssertEqual(CommandScore.score("hello", "hel"), 0.99, accuracy: 1e-12)
        XCTAssertEqual(CommandScore.score("Hello", "hello"), 0.9999, accuracy: 1e-12)
        XCTAssertEqual(CommandScore.score("hello", "x"), 0)
    }

    func testScoreOfWordJumpsAndSkippedCharacters() {
        // "w" after a space: 0.9, and the abbreviation ends before the string: 0.99.
        XCTAssertEqual(CommandScore.score("hello world", "hw"), 0.99 * 0.9, accuracy: 1e-12)
        // "c" after a skipped "b": 0.3 × 0.999.
        XCTAssertEqual(CommandScore.score("abc", "ac"), 0.3 * 0.999, accuracy: 1e-12)
        // "w" after a slash: 0.8.
        XCTAssertEqual(CommandScore.score("a/w", "aw"), 0.8, accuracy: 1e-12)
    }

    func testSearchScoresContainedKeysAsOne() {
        XCTAssertEqual(CommandSearch.score(keys: ["Set slice speed", "Slice"], query: "speed"), 1)
        // A key contained in the query also counts.
        XCTAssertEqual(CommandSearch.score(keys: ["Change zoom level", "Zoom"], query: "zoom lvl"), 1)
    }

    func testSearchFiltersAndRanks() {
        let items = ["Set slice speed", "Zoom in", "Zoom out", "Play"]
        XCTAssertEqual(CommandSearch.filter(items, query: "zoom") { [$0] }, ["Zoom out", "Zoom in"])
        XCTAssertEqual(CommandSearch.filter(items, query: "  ") { [$0] }, items)
        XCTAssertEqual(CommandSearch.filter(items, query: "qqq") { [$0] }, [])
    }

    func testTargetsKeepTheSelectionThenOneFocusedTargetPerKind() {
        enum Item: Hashable { case editor, zoom(Int), slice(Int) }
        func kind(_ item: Item) -> String {
            switch item {
            case .editor: "editor"
            case .zoom: "zoom"
            case .slice: "slice"
            }
        }
        var stack = ActionTargetStack<Item, String>(kind: kind)
        stack.focus(.editor)
        let open = stack.focus(.zoom(1))
        let hover = stack.focus(.zoom(2))
        XCTAssertEqual(stack.targets, [.zoom(2), .editor])
        stack.unfocus(hover)
        XCTAssertEqual(stack.targets, [.zoom(1), .editor])
        stack.unfocus(open)
        stack.focus(.slice(1))
        stack.toggleSelected(.zoom(3))
        stack.toggleSelected(.zoom(4))
        XCTAssertEqual(stack.targets, [.zoom(3), .zoom(4), .slice(1), .editor])
        // Another kind replaces the selection; toggling again removes.
        stack.toggleSelected(.slice(2))
        XCTAssertEqual(stack.selected, [.slice(2)])
        stack.toggleSelected(.slice(2))
        XCTAssertFalse(stack.hasSelection)
    }

    func testShortcutLabels() {
        XCTAssertEqual(ShortcutLabel.format(["Meta", "Shift", "Z"]), "⌘\u{00A0}⇧\u{00A0}Z")
        XCTAssertEqual(ShortcutLabel.format(["Meta", "Alt", "Z"]), "⌘\u{00A0}⌥\u{00A0}Z")
        XCTAssertEqual(ShortcutLabel.format(["Meta", "Control", "Enter"]), "⌘\u{00A0}Control\u{00A0}⏎")
        XCTAssertEqual(ShortcutLabel.format(["Control", "v"]), "Control\u{00A0}V")
        XCTAssertEqual(ShortcutLabel.format(["Backspace"]), "⌦")
        XCTAssertEqual(ShortcutLabel.format([" "]), "Space")
        XCTAssertEqual(ShortcutLabel.format(["Shift", "ArrowLeft"]), "⇧\u{00A0}←")
        XCTAssertEqual(ShortcutLabel.format(["Shift", "!"]), "!")
        XCTAssertEqual(ShortcutLabel.format(["Shift", "!", "Meta"]), "⌘\u{00A0}⇧\u{00A0}1")
    }

    func testFreeRangeSlidesLeftBeforeTheNextItem() {
        let items: [(start: Double, end: Double)] = [(0, 1000), (5000, 8000)]
        // Room ahead.
        XCTAssertEqual(TimelineFreeRange.at(1500, durationMs: 3000, items: items, minimumMs: 1000, totalMs: 10_000).map { [$0.start, $0.end] }, [1500, 4500])
        // Short of the next item: slid left, but not past the previous one.
        XCTAssertEqual(TimelineFreeRange.at(3000, durationMs: 3000, items: items, minimumMs: 1000, totalMs: 10_000).map { [$0.start, $0.end] }, [2000, 5000])
        XCTAssertEqual(TimelineFreeRange.at(1200, durationMs: 6000, items: items, minimumMs: 1000, totalMs: 10_000).map { [$0.start, $0.end] }, [1000, 5000])
        // Inside an item, or a gap shorter than the minimum.
        XCTAssertNil(TimelineFreeRange.at(500, durationMs: 3000, items: items, minimumMs: 1000, totalMs: 10_000))
        XCTAssertNil(TimelineFreeRange.at(1200, durationMs: 3000, items: [(0, 1000), (1500, 2000)], minimumMs: 1000, totalMs: 10_000))
    }
}
