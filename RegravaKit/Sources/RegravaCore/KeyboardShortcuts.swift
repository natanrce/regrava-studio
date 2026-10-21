import Foundation

// Keyboard shortcuts shown over the video: recorded key events become "presses" (timeline
// copy), each press becomes a row of key caps, and caps that stay between presses hand off.

/// A press: consecutive identical shortcuts merged.
public struct ShortcutPress: Hashable, Sendable {
    /// Key names (W3C `KeyboardEvent.key` style: "Meta", "Shift", "a", "ArrowUp"…).
    public var shortcut: [String]
    /// Every key down of the group, auto-repeats included.
    public var keyDowns: [Keystroke]
    public var firstKeyDownMs: Double
    public var lastKeyDownMs: Double
    /// Last key down or matched key up.
    public var lastEventMs: Double
    public var displayStartMs: Double
    public var displayEndMs: Double

    /// `captions.hiddenShortcuts` key: `String(firstKeyDownMs)` as JavaScript prints it.
    public var id: String { KeyboardShortcuts.jsNumberString(firstKeyDownMs) }
    /// Modifier keys of the shortcut.
    public var modifierKeys: [String] { shortcut.filter(KeyboardShortcuts.modifierNames.contains) }
}

/// One key cap.
public struct ShortcutKeyCap: Hashable, Sendable {
    public enum Placement: String, Hashable, Sendable { case center, bottomLeft = "bottom-left", bottomCenter = "bottom-center" }

    public var symbol: String?
    public var label: String
    public var widthRatio: Double
    public var placement: Placement

    /// Caps with the same identity stay on screen from one press to the next.
    public var identity: String { "\(placement.rawValue):\(label):\(symbol ?? "")" }
}

public enum KeyboardShortcuts {
    /// Gap that merges identical presses (called with 2000).
    public static let mergeGapMs = 2000.0
    /// A shifted key followed by plain typing this soon is a capital letter.
    static let typingGapMs = 1000.0
    /// How long a press stays after its last key down.
    static let displayAfterMs = 1500.0
    /// How far back a held modifier can show.
    static let holdLookBackMs = 3000.0

    static let modifierNames: Set<String> = ["Fn", "Ctrl", "Control", "CapsLock", "Alt", "Shift", "Meta"]

    /// Characters with their own key names.
    static let special: [String: [String]] = {
        var map: [String: [String]] = [
            "\u{09}": ["Tab"], "\u{0A}": ["Enter"], "\u{0D}": ["Enter"], "\u{19}": ["Shift", "Tab"],
            "\u{1B}": ["Escape"], "\u{7F}": ["Delete"], "\u{85}": ["Enter"], " ": [" "], "\u{08}": ["Backspace"],
            "\u{F700}": ["ArrowUp"], "\u{F701}": ["ArrowDown"], "\u{F702}": ["ArrowLeft"], "\u{F703}": ["ArrowRight"],
            "\u{F727}": ["Insert"], "\u{F728}": ["Delete"], "\u{F729}": ["Home"], "\u{F72B}": ["End"],
            "\u{F72C}": ["PageUp"], "\u{F72D}": ["PageDown"], "\u{F72E}": ["PrintScreen"], "\u{F72F}": ["ScrollLock"],
            "\u{F730}": ["Pause"], "\u{F746}": ["Help"],
        ]
        for i in 0..<12 { map[String(UnicodeScalar(0xF704 + i)!)] = ["F\(i + 1)"] }
        return map
    }()

    /// Characters that are key names by themselves (letters, digits, space, punctuation).
    static let knownCharacters: Set<String> = {
        var set = Set<String>()
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 []{}-_=+\\|;:'\",<.>/?`~!@#$%^&*()§" { set.insert(String(c)) }
        return set
    }()

    /// Single keys shown without "Show single key shortcuts".
    static let singleKeyAllowList: Set<String> = {
        var set: Set<String> = ["§", "CapsLock", "Backspace", "Delete", "ArrowDown", "ArrowLeft", "ArrowRight", "ArrowUp", "End", "Home", "PageDown", "PageUp"]
        for i in 1...20 { set.insert("F\(i)") }
        for i in 1...4 { set.insert("Soft\(i)") }
        return set
    }()

    /// A–z and characters of plain typing.
    static let typingCharacters: Set<String> = {
        var set: Set<String> = ["Decimal", "Multiply", "Add", "Clear", "Divide", "Subtract", "Separator", "Key11", "Key12"]
        for c in "abcdefghijklmnopqrstuvwxyz0123456789" { set.insert(String(c)) }
        return set
    }()

    /// Shifted digits back to their digit.
    static let shiftedDigits: [String: String] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"]

    static func keyName(_ modifier: KeyModifier) -> String? {
        switch modifier {
        case .capsLock: "CapsLock"
        case .command: "Meta"
        case .option: "Alt"
        case .shift: "Shift"
        case .control: "Ctrl"
        // The Fn flag macOS sets on arrows and F-keys is dropped.
        case .function: nil
        }
    }

    static func modifier(forKey key: String) -> KeyModifier? {
        switch key {
        case "Meta": .command
        case "Alt": .option
        case "Ctrl", "Control": .control
        case "Shift": .shift
        case "CapsLock": .capsLock
        case "Fn": .function
        default: nil
        }
    }

    /// An event's key list, or nil when it isn't a shortcut key.
    public static func shortcut(for event: Keystroke) -> [String]? {
        var keys = event.activeModifiers.compactMap(keyName)
        if let mapped = special[event.character] {
            keys += mapped
        } else if knownCharacters.contains(event.character) || !keys.isEmpty {
            keys.append(event.character)
        }
        var seen = Set<String>()
        keys = keys.filter { seen.insert($0).inserted }
        return keys.isEmpty ? nil : keys
    }

    private struct Item {
        var event: Keystroke
        var shortcut: [String]
    }

    /// Filtered key downs grouped into presses, without display times.
    private static func groups(_ keystrokes: [Keystroke], showSingleKeys: Bool) -> [[Item]] {
        let mapped = keystrokes.filter { $0.kind == .down }.compactMap { event in shortcut(for: event).map { Item(event: event, shortcut: $0) } }
        var filtered: [Item] = []
        for (i, item) in mapped.enumerated() {
            if i + 1 < mapped.count {
                let next = mapped[i + 1]
                if item.event.activeModifiers.contains(.shift), next.shortcut.count == 1, next.event.activeModifiers.isEmpty,
                   next.event.timeMs - item.event.timeMs < typingGapMs { continue }
            }
            if !showSingleKeys && item.shortcut.count == 1 && !singleKeyAllowList.contains(item.shortcut[0]) { continue }
            filtered.append(item)
        }
        var groups: [[Item]] = []
        for item in filtered {
            guard let last = groups.last, let first = last.first else {
                groups.append([item])
                continue
            }
            if showSingleKeys, first.event.activeModifiers.isEmpty, item.event.activeModifiers.isEmpty,
               typingCharacters.contains(first.event.character), typingCharacters.contains(item.event.character),
               item.event.timeMs - first.event.timeMs < typingGapMs {
                // Plain typing: the previous group goes and this key is not added.
                groups.removeLast()
                continue
            }
            if item.event.timeMs - last[last.count - 1].event.timeMs > mergeGapMs || last[0].shortcut != item.shortcut {
                groups.append([item])
            } else {
                groups[groups.count - 1].append(item)
            }
        }
        return groups
    }

    /// Every press of the recording, before cut and hidden filtering.
    public static func presses(keystrokes: [Keystroke], mouseEvents: [MouseEvent], showSingleKeys: Bool) -> [ShortcutPress] {
        let groups = groups(keystrokes, showSingleKeys: showSingleKeys)
        guard !groups.isEmpty else { return [] }

        // A non-repeat key down is matched with the next key up of the same character.
        var keyUpTime: [Double: Double] = [:]
        var pending: [String: Double] = [:]
        for event in keystrokes {
            let key = event.character.lowercased()
            if event.kind == .down {
                if !event.isARepeat { pending[key] = event.timeMs }
            } else if let down = pending.removeValue(forKey: key) {
                keyUpTime[down] = event.timeMs
            }
        }

        // Modifier states over time, keys and mouse merged.
        let states: [(t: Double, modifiers: [KeyModifier])] = (keystrokes.map { ($0.timeMs, $0.activeModifiers) }
            + mouseEvents.map { ($0.timeMs, $0.activeModifiers ?? []) }).sorted { $0.0 < $1.0 }

        var presses: [ShortcutPress] = []
        for group in groups {
            let downs = group.map(\.event)
            let first = downs[0].timeMs
            let lastDown = downs[downs.count - 1].timeMs
            var lastEvent = lastDown
            for down in downs where !down.isARepeat {
                if let up = keyUpTime[down.timeMs] { lastEvent = max(lastEvent, up) }
            }
            let previous = presses.last
            var press = ShortcutPress(shortcut: group[0].shortcut, keyDowns: downs, firstKeyDownMs: first, lastKeyDownMs: lastDown, lastEventMs: lastEvent, displayStartMs: 0, displayEndMs: lastDown + displayAfterMs)
            let a = first - 100
            var c = a
            for key in press.modifierKeys {
                c = min(c, holdStart(key, firstKeyDownMs: first, previous: previous, states: states) - 100)
            }
            if let previous { c = max(c, previous.displayStartMs + 800) }
            press.displayStartMs = min(a, c)
            presses.append(press)
        }
        return presses
    }

    /// `resolveModifierHoldStartMs`: how early the modifier was already held.
    static func holdStart(_ key: String, firstKeyDownMs first: Double, previous: ShortcutPress?, states: [(t: Double, modifiers: [KeyModifier])]) -> Double {
        guard key != "CapsLock", let modifier = modifier(forKey: key) else { return first }
        let floor = max(first - holdLookBackMs, previous.map { $0.lastEventMs + 1 } ?? -.infinity)
        guard var i = floorSearch(count: states.count, value: first - 1, key: { states[$0].t }) else { return first }
        var start = first
        while i >= 0 && states[i].t >= floor && states[i].modifiers.contains(modifier) {
            start = states[i].t
            i -= 1
        }
        return start
    }

    /// Presses shown in the video: inside the kept ranges and not hidden.
    public static func visiblePresses(project: Project) -> [ShortcutPress] {
        let config = project.captions
        let resolver = project.resolver
        return presses(keystrokes: project.keystrokes, mouseEvents: project.mouseEvents, showSingleKeys: config.showShortcutsWithSingleLetters)
            .filter { resolver.isSourceRangePresent($0.displayStartMs, $0.displayEndMs) && config.hiddenShortcuts[$0.id] != true }
    }

    // MARK: Key caps

    /// ⇧1 shows "!", ⌘⇧$ shows ⌘⇧4.
    static func fixShiftedDigits(_ keys: [String]) -> [String] {
        guard keys.contains("Shift"), keys.count > 1 else { return keys }
        if keys.count == 2, let other = keys.first(where: { $0 != "Shift" }), shiftedDigits[other] != nil { return [other] }
        return keys.map { shiftedDigits[$0] ?? $0 }
    }

    /// Stable sort by position in `order`; keys not in it keep their order after the others.
    static func ordered(_ keys: [String], by order: [String]) -> [String] {
        let known = keys.enumerated().filter { order.contains($0.element) }
            .sorted { (order.firstIndex(of: $0.element)!, $0.offset) < (order.firstIndex(of: $1.element)!, $1.offset) }
            .map(\.element)
        return known + keys.filter { !order.contains($0) }
    }

    static func upperFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Display names on macOS.
    static let displayNames: [String: String] = [
        "Alt": "⌥", "Meta": "⌘", "Enter": "⏎", "Shift": "⇧", "CapsLock": "⇪", "Ctrl": "⌃", "Control": "Control",
        "Backspace": "⌦", "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→", "Delete": "⌫",
        "PageDown": "Page Down", "PageUp": "Page Up", "PrintScreen": "Print Screen", "ScrollLock": "Scroll Lock",
        "Tab": "⇥", "End": "End", "Home": "Home", "Insert": "Insert", " ": "Space", "Escape": "Esc",
    ]

    public static func displayName(_ key: String) -> String { upperFirst(displayNames[key] ?? key) }

    /// The timeline's label: ⌘ ⇧ 4 joined by no-break spaces.
    public static func label(_ shortcut: [String]) -> String {
        fixShiftedDigits(ordered(shortcut.sorted(), by: ["Meta", "Shift", "Alt", "Ctrl", "Fn"])).map(displayName).joined(separator: "\u{00A0}")
    }

    /// The caps drawn for a press, modifiers first (fn ⇪ ⌘ ⌥ ⌃ ⇧).
    public static func keyCaps(_ shortcut: [String]) -> [ShortcutKeyCap] {
        let keys = fixShiftedDigits(shortcut)
        let order = ["Fn", "CapsLock", "Meta", "Alt", "Ctrl", "Control", "Shift"]
        let modifiers = ordered(keys.filter(modifierNames.contains), by: order)
        return modifiers.map(modifierCap) + keys.filter { !modifierNames.contains($0) }.map(keyCap)
    }

    static func modifierCap(_ key: String) -> ShortcutKeyCap {
        let (symbol, label): (String, String) = switch key {
        case "Fn": ("fn", "")
        case "Ctrl", "Control": ("⌃", "control")
        case "CapsLock": ("⇪", "caps lock")
        case "Alt": ("⌥", "option")
        case "Shift": ("⇧", "shift")
        default: ("⌘", "command")
        }
        return ShortcutKeyCap(symbol: symbol, label: label, widthRatio: 1.33, placement: .bottomLeft)
    }

    static func keyCap(_ key: String) -> ShortcutKeyCap {
        switch key {
        case "Escape": ShortcutKeyCap(symbol: "⎋", label: "esc", widthRatio: 1.33, placement: .bottomLeft)
        case "Enter": ShortcutKeyCap(symbol: nil, label: "⏎", widthRatio: 1.33, placement: .center)
        case "Tab": ShortcutKeyCap(symbol: "⇥", label: "tab", widthRatio: 1.33, placement: .bottomLeft)
        case "Backspace": ShortcutKeyCap(symbol: "⌦", label: "delete", widthRatio: 1.33, placement: .bottomLeft)
        case "Delete": ShortcutKeyCap(symbol: "⌫", label: "delete", widthRatio: 1.33, placement: .bottomLeft)
        case " ": ShortcutKeyCap(symbol: "␣", label: "space", widthRatio: 1.66, placement: .bottomCenter)
        default: ShortcutKeyCap(symbol: nil, label: displayName(key), widthRatio: 1, placement: .center)
        }
    }

    // MARK: Helpers

    /// `String(n)` for the numbers recordings use.
    public static func jsNumberString(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }
}

// MARK: - Timeline items

/// A chip on the timeline's Shortcuts track.
public struct ShortcutTrackItem: Hashable, Sendable, Identifiable {
    public var press: ShortcutPress
    public var startMs: Double
    public var endMs: Double
    public var label: String
    public var id: String { press.id }
}

public extension KeyboardShortcuts {
    /// Items of the Shortcuts track, hidden ones included, in source time.
    static func trackItems(project: Project) -> [ShortcutTrackItem] {
        let resolver = project.resolver
        let presses = presses(keystrokes: project.keystrokes, mouseEvents: project.mouseEvents, showSingleKeys: project.captions.showShortcutsWithSingleLetters)
            .filter { resolver.isSourceRangePresent($0.firstKeyDownMs - 100, $0.lastKeyDownMs + displayAfterMs) }
        var items: [ShortcutTrackItem] = []
        for (i, press) in presses.enumerated() {
            let t0 = press.firstKeyDownMs
            // Ms lead-in unless it would touch the previous chip.
            let start = items.last.map { t0 - $0.endMs > displayAfterMs ? t0 - 50 : t0 } ?? t0 - 50
            // Until 1620 ms after the last key down, or the next press.
            var end = press.lastKeyDownMs + displayAfterMs + 120
            if i + 1 < presses.count, presses[i + 1].firstKeyDownMs < end { end = presses[i + 1].firstKeyDownMs }
            items.append(ShortcutTrackItem(press: press, startMs: start, endMs: max(end, start + 50), label: label(press.shortcut).trimmingCharacters(in: .whitespaces)))
        }
        return items
    }
}

// MARK: - Overlay

/// A key cap living across consecutive presses.
public struct ShortcutKeyInstance: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public var pressIndex: Int
        public var keyIndex: Int
    }

    public var cap: ShortcutKeyCap
    public var segments: [Segment]
    public var appearKeyIndex: Int
    /// The press that replaced this cap, if any.
    public var handoffPressIndex: Int?
}

/// One key on screen.
public struct ShortcutKeyNode: Hashable, Sendable {
    /// Index of its instance, to pair it with the previous frame's node for motion blur.
    public var instance: Int
    public var cap: ShortcutKeyCap
    /// Sprung rect in canvas pixels (top-left origin).
    public var rect: Rect2
    /// Height of the key at rest: the cap's artwork scale.
    public var restingHeight: Double
    public var opacity: Double
}

/// The keyboard shortcuts overlay over time.
public struct ShortcutTrack: Sendable {
    public static let spring = SpringConfig(stiffness: 300, damping: 2, mass: 1.5, clampOvershoot: true, precision: 0.002)
    static let influenceMs = 1000.0

    public let presses: [ShortcutPress]
    public let instances: [ShortcutKeyInstance]
    let caps: [[ShortcutKeyCap]]
    let row: Rect2
    let rowHeight: Double
    public let sizeRatio: Double
    let resolver: TimeResolver
    public let fps: Double
    let fullscreenCameraRanges: [TimeRange]

    /// nil when shortcuts are off or there is nothing to show. `captionsShown`: transcript
    /// captions are on and have lines, so the row goes to the opposite side.
    public init?(project: Project, canvas: Rect2, captionsShown: Bool) {
        let config = project.captions
        guard config.enableShortcuts else { return nil }
        presses = KeyboardShortcuts.visiblePresses(project: project)
        guard !presses.isEmpty else { return nil }
        caps = presses.map { KeyboardShortcuts.keyCaps($0.shortcut) }
        sizeRatio = config.shortcutsSizeRatio
        // A row inside the stage padded by 5%, at the bottom or opposite the captions.
        let box = canvas.padByRatio(-0.05)
        rowHeight = canvas.height * sizeRatio
        let anchor = captionsShown ? Vec2(0.5, 1 - config.position01.y) : Vec2(0.5, 1)
        row = Rect2(x: 0, y: 0, width: box.width, height: rowHeight).fitInside(box, anchor: anchor)
        resolver = project.resolver
        fps = max(Double(project.recording.fps), 1)
        fullscreenCameraRanges = project.recording.hasCamera
            ? project.cameraLayouts.filter { $0.type == .fullscreenCamera && !$0.isDisabled }.map { TimeRange(startMs: $0.startMs, endMs: $0.endMs) }
            : []

        var instances: [ShortcutKeyInstance] = []
        var live: [String: Int] = [:]
        for (p, press) in presses.enumerated() {
            if p > 0, press.displayStartMs <= presses[p - 1].displayEndMs {
                let identities = Set(caps[p].map(\.identity))
                for (id, index) in live where !identities.contains(id) {
                    instances[index].handoffPressIndex = p
                    live[id] = nil
                }
            } else {
                live.removeAll()
            }
            for (k, cap) in caps[p].enumerated() {
                if let index = live[cap.identity] {
                    instances[index].segments.append(.init(pressIndex: p, keyIndex: k))
                } else {
                    live[cap.identity] = instances.count
                    instances.append(ShortcutKeyInstance(cap: cap, segments: [.init(pressIndex: p, keyIndex: k)], appearKeyIndex: k))
                }
            }
        }
        self.instances = instances
    }

    /// The resting key rects of a press, centred in the row and shrunk to fit it.
    public func keyRects(pressIndex: Int) -> [Rect2] {
        let caps = caps[pressIndex]
        let h = rowHeight
        let gap = h * 0.1
        let widths = caps.map { h * $0.widthRatio }
        let total = widths.reduce(0, +) + gap * Double(max(caps.count - 1, 0))
        let fit = Rect2(x: 0, y: 0, width: total, height: h).fitInside(row)
        let k = fit.height / h
        var x = fit.x
        return widths.map { w in
            let rect = Rect2(x: x, y: fit.y, width: w * k, height: fit.height)
            x = rect.endX + gap * k
            return rect
        }
    }

    func displayStart(_ instance: ShortcutKeyInstance) -> Double { presses[instance.segments[0].pressIndex].displayStartMs }

    func displayEnd(_ instance: ShortcutKeyInstance) -> Double {
        if let h = instance.handoffPressIndex { return presses[h].displayStartMs + 100 }
        return presses[instance.segments[instance.segments.count - 1].pressIndex].displayEndMs
    }

    private func isFullscreenCamera(_ t: Double) -> Bool {
        fullscreenCameraRanges.contains { t >= $0.startMs && t <= $0.endMs }
    }

    /// Where the cap should be at source time `t`.
    func target(_ instance: ShortcutKeyInstance, atSource t: Double) -> (rect: Rect2, opacity: Double) {
        let start = displayStart(instance), end = displayEnd(instance)
        let segment = instance.segments.last { presses[$0.pressIndex].displayStartMs <= t } ?? instance.segments[0]
        let resting = keyRects(pressIndex: segment.pressIndex)[segment.keyIndex]
        let inRange = start <= t && t <= end
        let appearMs = start + Double(instance.appearKeyIndex) * 60
        let appear = clamp((t - appearMs) / 100, 0, 1)
        var handoff = 0.0
        if let h = instance.handoffPressIndex, t >= presses[h].displayStartMs {
            handoff = clamp((t - presses[h].displayStartMs) / 100, 0, 1)
        }
        let opacity = !inRange || isFullscreenCamera(t) ? 0 : (handoff > 0 ? 1 - handoff : appear)
        let lift = inRange ? -1 + (1 - handoff) * appear : -1
        var rect = resting
        rect.y += lift * resting.height * -0.033
        return (rect, opacity)
    }

    /// Height of the cap at rest at `t` (the artwork scale, not sprung).
    func restingHeight(_ instance: ShortcutKeyInstance, atSource t: Double) -> Double {
        let segment = instance.segments.last { presses[$0.pressIndex].displayStartMs <= t } ?? instance.segments[0]
        return keyRects(pressIndex: segment.pressIndex)[segment.keyIndex].height
    }

    /// Keys on screen at a playback time, with springs run over the last second of frames.
    public func scene(atPlayback time: Double) -> [ShortcutKeyNode] {
        let step = 1000 / fps
        let steps = Int((Self.influenceMs / step).rounded())
        let sources = (0...steps).map { resolver.playbackToSource(max(time - Double(steps - $0) * step, 0)) }
        guard let lo = sources.min(), let hi = sources.max() else { return [] }
        var nodes: [ShortcutKeyNode] = []
        for (index, instance) in instances.enumerated() where displayStart(instance) - 200 <= hi && displayEnd(instance) + Self.influenceMs >= lo {
            var rect: SpringRect?
            var opacity = SpringValue(0)
            for t in sources {
                let target = target(instance, atSource: t)
                if rect == nil {
                    rect = SpringRect(target.rect)
                    opacity = SpringValue(target.opacity)
                } else {
                    rect!.advance(toward: target.rect, config: Self.spring, milliseconds: step)
                    opacity.advance(toward: target.opacity, config: Self.spring, milliseconds: step)
                }
            }
            let alpha = clamp(opacity.value, 0, 1)
            guard let rect, alpha > 0.001 else { continue }
            nodes.append(ShortcutKeyNode(instance: index, cap: instance.cap, rect: rect.rect, restingHeight: restingHeight(instance, atSource: sources[sources.count - 1]), opacity: alpha))
        }
        return nodes
    }

    /// The current press's key rects: the paused preview's click target.
    public func currentRect(atPlayback time: Double) -> Rect2? {
        let t = resolver.playbackToSource(time)
        guard let index = presses.lastIndex(where: { $0.displayStartMs <= t }), t <= presses[index].displayEndMs else { return nil }
        let rects = keyRects(pressIndex: index)
        guard let first = rects.first, let last = rects.last else { return nil }
        return Rect2(x: first.x, y: first.y, width: last.endX - first.x, height: first.height)
    }
}
