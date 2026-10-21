import Testing
@testable import RegravaCore

@Suite struct KeyboardShortcutsTests {
    private func press(_ character: String, _ modifiers: [KeyModifier] = [], at t: Double, holdMs: Double = 80) -> [Keystroke] {
        [Keystroke(kind: .down, timeMs: t, character: character, activeModifiers: modifiers),
         Keystroke(kind: .up, timeMs: t + holdMs, character: character, activeModifiers: modifiers)]
    }

    private func project(_ keys: [Keystroke], mouse: [MouseEvent] = []) -> Project {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 20_000, fps: 60), mouseEvents: mouse)
        p.keystrokes = keys.sorted { $0.timeMs < $1.timeMs }
        p.captions.enableShortcuts = true
        return p
    }

    @Test func commandShiftFourShowsTheDigit() {
        let event = Keystroke(kind: .down, timeMs: 0, character: "$", activeModifiers: [.command, .shift])
        let shortcut = KeyboardShortcuts.shortcut(for: event)
        #expect(shortcut == ["Meta", "Shift", "$"])
        let caps = KeyboardShortcuts.keyCaps(shortcut!)
        #expect(caps.map(\.symbol) == ["⌘", "⇧", nil])
        #expect(caps.map(\.label) == ["command", "shift", "4"])
        #expect(caps.map(\.widthRatio) == [1.33, 1.33, 1])
        #expect(KeyboardShortcuts.label(shortcut!) == "⌘\u{00A0}⇧\u{00A0}4")
        // ⇧1 alone keeps "!".
        #expect(KeyboardShortcuts.keyCaps(["Shift", "!"]).map(\.label) == ["!"])
    }

    @Test func functionFlagIsIgnoredAndArrowsHaveNames() {
        let arrow = Keystroke(kind: .down, timeMs: 0, character: "\u{F702}", activeModifiers: [.function])
        #expect(KeyboardShortcuts.shortcut(for: arrow) == ["ArrowLeft"])
        #expect(KeyboardShortcuts.keyCaps(["ArrowLeft"]).map(\.label) == ["←"])
        #expect(KeyboardShortcuts.shortcut(for: Keystroke(kind: .down, timeMs: 0, character: "\u{F70F}")) == ["F12"])
        // Unknown characters without modifiers are not shortcuts.
        #expect(KeyboardShortcuts.shortcut(for: Keystroke(kind: .down, timeMs: 0, character: "é")) == nil)
        #expect(KeyboardShortcuts.shortcut(for: Keystroke(kind: .down, timeMs: 0, character: "")) == nil)
    }

    @Test func singleKeysNeedTheOptionExceptTheAllowList() {
        let keys = press("a", at: 1000) + press("\u{7F}", at: 4000) + press("\u{F700}", at: 8000)
        let presses = KeyboardShortcuts.presses(keystrokes: keys.sorted { $0.timeMs < $1.timeMs }, mouseEvents: [], showSingleKeys: false)
        #expect(presses.map(\.shortcut) == [["Delete"], ["ArrowUp"]])
        let all = KeyboardShortcuts.presses(keystrokes: keys.sorted { $0.timeMs < $1.timeMs }, mouseEvents: [], showSingleKeys: true)
        #expect(all.map(\.shortcut) == [["a"], ["Delete"], ["ArrowUp"]])
    }

    @Test func capitalLetterFollowedByTypingIsHidden() {
        let keys = press("H", [.shift], at: 1000) + press("i", at: 1200) + press("k", [.command], at: 5000)
        let presses = KeyboardShortcuts.presses(keystrokes: keys, mouseEvents: [], showSingleKeys: false)
        #expect(presses.map(\.shortcut) == [["Meta", "k"]])
    }

    @Test func identicalPressesWithinTwoSecondsMerge() {
        let keys = press("c", [.command], at: 1000) + press("c", [.command], at: 2500) + press("c", [.command], at: 5000)
        let presses = KeyboardShortcuts.presses(keystrokes: keys, mouseEvents: [], showSingleKeys: false)
        #expect(presses.count == 2)
        #expect(presses[0].keyDowns.count == 2)
        #expect(presses[0].firstKeyDownMs == 1000 && presses[0].lastKeyDownMs == 2500 && presses[0].lastEventMs == 2580)
        #expect(presses[0].displayEndMs == 4000)
        #expect(presses[0].id == "1000")
    }

    @Test func heldModifierShowsEarly() {
        let mouse = [
            MouseEvent(kind: .move, timeMs: 3000, position: Vec2(0, 0)),
            MouseEvent(kind: .move, timeMs: 3400, position: Vec2(1, 0), activeModifiers: [.command]),
            MouseEvent(kind: .move, timeMs: 3800, position: Vec2(2, 0), activeModifiers: [.command]),
        ]
        let presses = KeyboardShortcuts.presses(keystrokes: press("s", [.command], at: 4000), mouseEvents: mouse, showSingleKeys: false)
        #expect(presses[0].displayStartMs == 3300)
        // Without a held modifier the press starts 100 ms early.
        let plain = KeyboardShortcuts.presses(keystrokes: press("s", [.command], at: 4000), mouseEvents: [], showSingleKeys: false)
        #expect(plain[0].displayStartMs == 3900)
    }

    @Test func rowGeometryMatchesReference() throws {
        let p = project(press("$", [.command, .shift], at: 1000))
        let track = try #require(ShortcutTrack(project: p, canvas: Rect2(x: 0, y: 0, width: 1920, height: 1080), captionsShown: false))
        let rects = track.keyRects(pressIndex: 0)
        #expect(abs(rects[0].x - 751.56) < 0.01)
        #expect(abs(rects[0].y - 922.91) < 0.01)
        #expect(abs(rects[0].width - 143.64) < 0.01 && rects[0].height == 108)
        #expect(abs(rects[2].x - (751.56 + 143.64 * 2 + 21.6)) < 0.02)
    }

    @Test func sharedKeysHandOff() throws {
        let keys = press("c", [.command], at: 1000) + press("v", [.command], at: 1600)
        let track = try #require(ShortcutTrack(project: project(keys), canvas: Rect2(x: 0, y: 0, width: 1920, height: 1080), captionsShown: false))
        #expect(track.instances.count == 3)
        let command = track.instances[0]
        #expect(command.cap.symbol == "⌘" && command.segments.count == 2)
        #expect(track.instances[1].cap.label == "C" && track.instances[1].handoffPressIndex == 1)

        let settled = track.scene(atPlayback: 1500)
        #expect(settled.count == 2)
        #expect(settled.allSatisfy { $0.opacity > 0.99 })
        let rest = track.keyRects(pressIndex: 0)
        #expect(abs(settled[0].rect.y - rest[0].y) < 0.1)
        // Long after the last press nothing is shown.
        #expect(track.scene(atPlayback: 6000).isEmpty)
    }

    @Test func hiddenPressesAreLeftOutOfTheVideoButKeptOnTheTimeline() {
        var p = project(press("k", [.command], at: 1000) + press("j", [.command], at: 6000))
        p.captions.hiddenShortcuts = ["1000": true]
        #expect(KeyboardShortcuts.visiblePresses(project: p).map(\.firstKeyDownMs) == [6000])
        let items = KeyboardShortcuts.trackItems(project: p)
        #expect(items.count == 2)
        #expect(items[0].startMs == 950 && items[0].endMs == 2620)
        #expect(items[0].label == "⌘\u{00A0}K")
    }

    @Test func rowMovesOppositeTheCaptions() throws {
        var p = project(press("k", [.command], at: 1000))
        p.captions.position01 = Vec2(0.5, 1)
        let track = try #require(ShortcutTrack(project: p, canvas: Rect2(x: 0, y: 0, width: 1920, height: 1080), captionsShown: true))
        #expect(abs(track.keyRects(pressIndex: 0)[0].y - 49.09) < 0.01)
    }

    @Test func numbersPrintLikeJavaScript() {
        #expect(KeyboardShortcuts.jsNumberString(1234) == "1234")
        #expect(KeyboardShortcuts.jsNumberString(1234.5) == "1234.5")
    }
}
