import Foundation

/// Fuzzy score of an abbreviation against a string, 0…1 (command-score): consecutive
/// characters score highest, characters after a word break or punctuation a little less, and
/// skipped characters cost a little each.
public enum CommandScore {
    static let continueMatch = 1.0
    static let spaceWordJump = 0.9
    static let nonSpaceWordJump = 0.8
    static let characterJump = 0.3
    static let transpositionMinimum = 0.1
    static let penaltySkipped = 0.999
    static let penaltyCaseMismatch = 0.9999
    static let penaltyNotComplete = 0.99

    private static let gapCharacters = Set("\\/_+.#\"@[({&".utf16)
    private static let spaceCharacters = Set(" \t\n\r\u{0B}\u{0C}-".utf16)

    public static func score(_ string: String, _ abbreviation: String) -> Double {
        var memo: [Int: Double] = [:]
        return score(Array(string.utf16), Array(abbreviation.utf16), normalize(string), normalize(abbreviation), 0, 0, &memo)
    }

    /// Lowercased, with whitespace and dashes as spaces.
    private static func normalize(_ value: String) -> [UInt16] {
        value.lowercased().utf16.map { spaceCharacters.contains($0) ? 32 : $0 }
    }

    private static func at(_ array: [UInt16], _ index: Int) -> UInt16? {
        array.indices.contains(index) ? array[index] : nil
    }

    private static func count(_ array: [UInt16], from start: Int, to end: Int, in set: Set<UInt16>) -> Int {
        let end = min(end, array.count)
        guard start < end else { return 0 }
        return array[start..<end].filter { set.contains($0) }.count
    }

    private static func firstIndex(of character: UInt16, in array: [UInt16], from start: Int) -> Int? {
        guard start < array.count else { return nil }
        return array[max(start, 0)...].firstIndex(of: character)
    }

    private static func score(
        _ string: [UInt16], _ abbreviation: [UInt16], _ lowerString: [UInt16], _ lowerAbbreviation: [UInt16],
        _ stringIndex: Int, _ abbreviationIndex: Int, _ memo: inout [Int: Double]
    ) -> Double {
        if abbreviationIndex == abbreviation.count {
            return stringIndex == string.count ? continueMatch : penaltyNotComplete
        }
        let key = stringIndex &* 100_003 &+ abbreviationIndex
        if let cached = memo[key] { return cached }
        let abbreviationChar = lowerAbbreviation[abbreviationIndex]
        var index = firstIndex(of: abbreviationChar, in: lowerString, from: stringIndex)
        var highScore = 0.0
        while let found = index {
            var score = self.score(string, abbreviation, lowerString, lowerAbbreviation, found + 1, abbreviationIndex + 1, &memo)
            if score > highScore {
                if found == stringIndex {
                    score *= continueMatch
                } else if let previous = at(string, found - 1), gapCharacters.contains(previous) {
                    score *= nonSpaceWordJump
                    let breaks = count(string, from: stringIndex, to: found - 1, in: gapCharacters)
                    if breaks > 0 && stringIndex > 0 { score *= pow(penaltySkipped, Double(breaks)) }
                } else if let previous = at(string, found - 1), spaceCharacters.contains(previous) {
                    score *= spaceWordJump
                    let breaks = count(string, from: stringIndex, to: found - 1, in: spaceCharacters)
                    if breaks > 0 && stringIndex > 0 { score *= pow(penaltySkipped, Double(breaks)) }
                } else {
                    score *= characterJump
                    if stringIndex > 0 { score *= pow(penaltySkipped, Double(found - stringIndex)) }
                }
                if at(string, found) != at(abbreviation, abbreviationIndex) { score *= penaltyCaseMismatch }
            }
            let nextAbbreviation = at(lowerAbbreviation, abbreviationIndex + 1)
            if (score < transpositionMinimum && at(lowerString, found - 1) == nextAbbreviation)
                || (nextAbbreviation == abbreviationChar && at(lowerString, found - 1) != abbreviationChar) {
                let transposed = self.score(string, abbreviation, lowerString, lowerAbbreviation, found + 1, abbreviationIndex + 2, &memo)
                if transposed * transpositionMinimum > score { score = transposed * transpositionMinimum }
            }
            if score > highScore { highScore = score }
            index = firstIndex(of: abbreviationChar, in: lowerString, from: found + 1)
        }
        memo[key] = highScore
        return highScore
    }
}

/// The command menu's search: every key of an item (its name, supplementary label and groups)
/// is scored against the query, and items below the threshold are left out.
public enum CommandSearch {
    public static let threshold = 0.09

    /// 1 when a key contains the query (or the query contains a key), otherwise the best fuzzy
    /// score of any key, or of all keys joined, against the query or its words reversed (at half
    /// weight), times 0.9.
    public static func score(keys: [String], query: String) -> Double {
        var keys = keys
        keys.append(keys.joined(separator: " "))
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if keys.contains(where: {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return key.contains(normalizedQuery) || normalizedQuery.contains(key)
        }) { return 1 }
        let reversed = query.components(separatedBy: " ").reversed().joined(separator: " ")
        var best = -Double((Int64(1) << 53) - 1)
        for key in keys {
            best = max(best, CommandScore.score(key, query))
            best = max(best, CommandScore.score(key, reversed) / 2)
        }
        return best * 0.9
    }

    /// Items matching the query, best first (equal scores in reverse order); every item, in
    /// order, when the query is blank.
    public static func filter<Item>(_ items: [Item], query: String, threshold: Double = threshold, keys: (Item) -> [String]) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let scored = items.enumerated()
            .map { (offset: $0.offset, score: score(keys: keys($0.element).filter { !$0.isEmpty }, query: query), item: $0.element) }
            .filter { $0.score > 0 }
        // A stable ascending sort, then reversed.
        let ascending = scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.offset < $1.offset }
        return ascending.reversed().filter { $0.score >= threshold }.map(\.item)
    }
}

/// Targets of actions: the selection (items of one kind), then the most recently focused
/// target of every other kind (hover, an open inspector, the editor itself).
public struct ActionTargetStack<Target: Hashable, Kind: Hashable> {
    public typealias Token = Int

    public private(set) var selected: [Target] = []
    private var focused: [(token: Token, target: Target)] = []
    private var nextToken: Token = 0
    private let kind: (Target) -> Kind

    public init(kind: @escaping (Target) -> Kind) {
        self.kind = kind
    }

    public var targets: [Target] { targets { _ in true } }

    /// The targets, skipping the ones that no longer exist.
    public func targets(where isValid: (Target) -> Bool) -> [Target] {
        var result = selected.filter(isValid)
        var kinds = Set(result.map(kind))
        for entry in focused.reversed() where isValid(entry.target) && !kinds.contains(kind(entry.target)) {
            if !result.contains(entry.target) { result.append(entry.target) }
            kinds.insert(kind(entry.target))
        }
        return result
    }

    public var focusedTarget: Target? { focused.last?.target }
    public var hasSelection: Bool { !selected.isEmpty }

    @discardableResult
    public mutating func focus(_ target: Target) -> Token {
        nextToken += 1
        focused.append((nextToken, target))
        return nextToken
    }

    public mutating func unfocus(_ token: Token) {
        focused.removeAll { $0.token == token }
    }

    public mutating func setSelected(_ targets: [Target]) {
        var unique: [Target] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        selected = unique
    }

    /// ⌘-click: removes a selected target, otherwise adds it, after clearing a selection of
    /// another kind.
    public mutating func toggleSelected(_ target: Target) {
        if let index = selected.firstIndex(of: target) {
            selected.remove(at: index)
            return
        }
        if selected.contains(where: { kind($0) != kind(target) }) { selected.removeAll() }
        selected.append(target)
    }

    public mutating func clearSelected() { selected.removeAll() }

    public mutating func removeSelected(where predicate: (Target) -> Bool) {
        selected.removeAll(where: predicate)
    }

    public func isSelected(_ target: Target) -> Bool { selected.contains(target) }
    public func isFocused(_ target: Target) -> Bool { focusedTarget == target }
}

/// A shortcut's keys as shown on its badge: modifiers first (⌘ ⇧ ⌥ ⌃), symbols for special keys,
/// separated by non-breaking spaces.
public enum ShortcutLabel {
    private static let modifierOrder = ["Meta", "Shift", "Alt", "Ctrl", "Fn"]
    private static let symbols: [String: String] = [
        "Alt": "⌥", "Meta": "⌘", "Enter": "⏎", "Shift": "⇧", "CapsLock": "⇪", "Ctrl": "⌃",
        "Control": "Control", "Backspace": "⌦", "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←",
        "ArrowRight": "→", "Delete": "⌫", "PageDown": "Page Down", "PageUp": "Page Up",
        "PrintScreen": "Print Screen", "ScrollLock": "Scroll Lock", "Tab": "⇥", "End": "End",
        "Home": "Home", "Insert": "Insert", " ": "Space", "Escape": "Esc",
    ]
    private static let shiftedDigits: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]

    public static func format(_ keys: [String]) -> String {
        parts(keys).joined(separator: "\u{00A0}")
    }

    public static func parts(_ keys: [String]) -> [String] {
        // Sorted by UTF-16 code units, then modifiers first with a binary insertion sort whose
        // comparator puts unknown keys after everything (so they keep their order).
        var sorted = keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        func compare(_ a: String, _ b: String) -> Int {
            guard let ia = modifierOrder.firstIndex(of: a) else { return 1 }
            guard let ib = modifierOrder.firstIndex(of: b) else { return -1 }
            return ia - ib
        }
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                let pivot = sorted[i]
                var left = 0, right = i
                while left < right {
                    let mid = left + ((right - left) >> 1)
                    if compare(pivot, sorted[mid]) < 0 { right = mid } else { left = mid + 1 }
                }
                sorted.remove(at: i)
                sorted.insert(pivot, at: left)
            }
        }
        if sorted.contains("Shift") && sorted.count > 1 {
            if sorted.count == 2, let other = sorted.first(where: { $0 != "Shift" }), shiftedDigits[other] != nil {
                sorted = [other]
            } else {
                sorted = sorted.map { shiftedDigits[$0] ?? $0 }
            }
        }
        return sorted.map { key in
            let label = symbols[key] ?? key
            guard let first = label.first else { return label }
            return first.uppercased() + label.dropFirst()
        }
    }
}

/// Free ranges for timeline items (zooms, layouts, masks) sorted by start.
public enum TimelineFreeRange {
    /// `getFreeRangeAt`: a range of `durationMs` ending at most at the next item (or the end),
    /// slid left as far as the previous item allows; nil inside an item or when the gap is
    /// shorter than `minimumMs`.
    public static func at(_ timeMs: Double, durationMs: Double, items: [(start: Double, end: Double)], minimumMs: Double, totalMs: Double) -> (start: Double, end: Double)? {
        if items.contains(where: { $0.start < timeMs && $0.end > timeMs }) { return nil }
        let previousEnd = items.last(where: { $0.end <= timeMs })?.end ?? 0
        let nextStart = items.first(where: { $0.start >= timeMs })?.start ?? totalMs
        if nextStart - previousEnd < minimumMs { return nil }
        let end = min(nextStart, timeMs + durationMs)
        return (max(previousEnd, end - durationMs), end)
    }
}
