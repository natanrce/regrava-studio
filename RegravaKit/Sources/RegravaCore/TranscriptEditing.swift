import Foundation

// "Edit by transcript": tokens, paragraphs, filler words and the mapping of deleted words to slice cuts.

/// A word or a pause of at least 1 s between words, in source time.
public struct TranscriptToken: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case word, gap }

    public var id: String
    public var index: Int
    public var kind: Kind
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var text: String
    public var fillerTier: Int?
    public var isHidden: Bool
    public var wordType: String?
    public var sessionIndex: Int
    public var sessionOffsetMs: Double
    /// Index into the session's words (nil for a gap).
    public var wordIndex: Int?
}

public enum FillerWords {
    /// Tier 1 (filled pauses) and tier 2 (discourse markers) per language.
    static let lists: [String: (tier1: Set<String>, tier2: Set<String>)] = [
        "en": (["um", "uh", "er", "ah", "hmm", "mhmm", "mm", "mmm", "huh", "uh-huh", "erm", "umm", "uhh"],
               ["like", "you know", "so", "i mean", "kind of", "sort of", "actually", "basically", "literally"]),
        "de": (["äh", "ähm", "hm", "mhm", "öh", "öhm"], ["halt", "also", "quasi", "sozusagen", "naja"]),
        "fr": (["euh", "hein", "ben", "bah"], ["genre", "tu vois", "en fait", "du coup", "quoi"]),
        "es": (["eh", "em", "este", "mmm"], ["pues", "o sea", "bueno", "es que", "digamos"]),
        "pt": (["é", "hã", "ãh", "hum"], ["né", "tipo", "então", "sabe", "assim"]),
        "it": (["ehm", "eh", "mah"], ["cioè", "allora", "tipo", "insomma", "diciamo"]),
        "pl": (["yyy", "eee", "hmm", "yhm"], ["no", "wiesz", "znaczy", "jakby", "w sensie"]),
        "nl": (["uh", "uhm", "eh", "ehm"], ["nou", "weet je", "zeg maar", "dus"]),
    ]

    /// `normalize`: lower-cased letters, digits, spaces and hyphens.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-" })
            .trimmingCharacters(in: .whitespaces)
    }

    public static func tier(_ text: String, locale: String?) -> Int? {
        let lang = String((locale ?? "en").prefix(2)).lowercased()
        let list = lists[lang] ?? lists["en"]!
        let n = normalize(text)
        if n.isEmpty { return nil }
        if list.tier1.contains(n) { return 1 }
        if list.tier2.contains(n) { return 2 }
        return nil
    }
}

public enum TranscriptEditing {
    static let gapMinMs = 1000.0
    /// `SliceModel.MIN_DURATION_MS`.
    static let minSliceMs = Slice.minimumDurationMs

    /// Words of one session (session-file time) as tokens.
    public static func tokens(_ words: [TranscriptWord], sessionIndex: Int = 0, sessionOffsetMs: Double = 0, locale: String?) -> [TranscriptToken] {
        var out: [TranscriptToken] = []
        var last: TranscriptToken?
        for (j, w) in words.enumerated() {
            let s = TranscriptTiming.onsetMs(w) + sessionOffsetMs
            let e = w.endMs + sessionOffsetMs
            if let last, s - last.sourceEndMs >= gapMinMs {
                out.append(TranscriptToken(id: "gap:\(sessionIndex):\(j)", index: out.count, kind: .gap, sourceStartMs: last.sourceEndMs, sourceEndMs: s, text: "",
                                           fillerTier: nil, isHidden: false, wordType: nil, sessionIndex: sessionIndex, sessionOffsetMs: sessionOffsetMs, wordIndex: nil))
            }
            let token = TranscriptToken(id: "word:\(sessionIndex):\(j)", index: out.count, kind: .word, sourceStartMs: s, sourceEndMs: max(e, s + 1),
                                        text: w.text.trimmingCharacters(in: .whitespacesAndNewlines), fillerTier: FillerWords.tier(w.text, locale: locale),
                                        isHidden: w.isHidden ?? false, wordType: w.type, sessionIndex: sessionIndex, sessionOffsetMs: sessionOffsetMs, wordIndex: j)
            out.append(token)
            last = token
        }
        return out
    }

    /// Paragraphs break on long pauses, sessions and every 4 sentences.
    public static func paragraphs(_ tokens: [TranscriptToken]) -> [[TranscriptToken]] {
        func sentenceEnd(_ t: TranscriptToken) -> Bool { t.kind == .word && (t.text.hasSuffix(".") || t.text.hasSuffix("?") || t.text.hasSuffix("!")) }
        var result: [[TranscriptToken]] = []
        var current: [TranscriptToken] = []
        var count = 0
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = []
            count = 0
        }
        for t in tokens {
            let prev = current.last
            let newSession = prev.map { $0.sessionIndex != t.sessionIndex } ?? false
            let gapLength = t.kind == .gap ? t.sourceEndMs - t.sourceStartMs : 0
            let bigGap = t.kind == .gap && (gapLength >= 2000 || (gapLength >= 1200 && prev.map(sentenceEnd) == true))
            if newSession || (bigGap && !current.isEmpty) { flush() }
            current.append(t)
            if sentenceEnd(t) {
                count += 1
                if count >= 4 { flush() }
            }
        }
        flush()
        return result
    }

    // MARK: Cuts

    struct Context {
        var previousKeptEnd: Double?
        var nextKeptStart: Double?
        var sessionStart: Double?
    }

    /// About 40 ms of air around the deleted words.
    static func padNormal(_ s: Double, _ e: Double, _ c: Context) -> (Double, Double) {
        var cs: Double, ce: Double
        if let p = c.previousKeptEnd, !(c.sessionStart.map { p < $0 } ?? false) {
            let g = s - p
            cs = g < 60 ? p + g / 2 : max(s - 40, p + 30)
        } else {
            cs = c.sessionStart ?? s - 40
        }
        if let n = c.nextKeptStart {
            let g = n - e
            ce = g < 60 ? e + g / 2 : min(e + 40, n - 30)
        } else {
            ce = e + 40
        }
        return (cs, max(ce, cs))
    }

    /// A run of only filled pauses also takes the pauses around it.
    static func padFiller(_ s: Double, _ e: Double, _ c: Context) -> (Double, Double) {
        var cs: Double, ce: Double
        if let p = c.previousKeptEnd, !(c.sessionStart.map { p < $0 } ?? false) {
            let g = s - p
            cs = g < 60 ? p + g / 2 : p + 30
        } else {
            cs = c.sessionStart ?? s - 40
        }
        if let n = c.nextKeptStart {
            let g = n - e
            ce = g < 60 ? e + g / 2 : n - 30
        } else {
            ce = e + 40
        }
        return (cs, max(ce, cs))
    }

    /// Parts of `[s, e]` inside the ranges.
    static func intersect(_ s: Double, _ e: Double, _ ranges: [(Double, Double)]) -> [(Double, Double)] {
        ranges.compactMap { r in
            let a = max(s, r.0), b = min(e, r.1)
            return b > a ? (a, b) : nil
        }
    }

    /// A pause keeps 100 ms of air on each side of each present part.
    static func tighten(_ s: Double, _ e: Double, present: [(Double, Double)]) -> [(Double, Double)] {
        let parts = present.isEmpty ? [(s, e)] : intersect(s, e, present)
        if parts.isEmpty || parts.reduce(0, { $0 + $1.1 - $1.0 }) <= 200 { return [] }
        return parts.filter { $0.1 - $0.0 > 200 }.map { ($0.0 + 100, $0.1 - 100) }.filter { $0.1 > $0.0 }
    }

    /// Merges ranges closer than `tolerance`.
    static func merge(_ ranges: [(Double, Double)], tolerance: Double = 60) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, r.0 <= last.1 + tolerance {
                out[out.count - 1].1 = max(last.1, r.1)
            } else {
                out.append(r)
            }
        }
        return out
    }

    public static func presentRanges(_ project: Project) -> [(Double, Double)] {
        project.slices.map { ($0.sourceStartMs, $0.sourceEndMs) }.sorted { $0.0 < $1.0 }
    }

    public static func isPresent(_ token: TranscriptToken, in project: Project) -> Bool {
        project.resolver.isSourceRangePresent(token.sourceStartMs, token.sourceEndMs)
    }

    public static func canTighten(_ gap: TranscriptToken, in project: Project) -> Bool {
        gap.kind == .gap && !tighten(gap.sourceStartMs, gap.sourceEndMs, present: presentRanges(project)).isEmpty
    }

    /// The source ranges to cut for deleted tokens.
    static func cutRanges(tokens: [TranscriptToken], deleted: [TranscriptToken], project: Project) -> [(Double, Double)] {
        let present = presentRanges(project)
        let deletedSet = Set(deleted.map(\.index))
        func keptWord(_ i: Int) -> Bool {
            tokens[i].kind == .word && !deletedSet.contains(i) && isPresent(tokens[i], in: project)
        }
        let sorted = deleted.map(\.index).sorted()
        var runs: [[Int]] = []
        for i in sorted {
            if let last = runs.last?.last, last + 1 == i { runs[runs.count - 1].append(i) } else { runs.append([i]) }
        }
        var out: [(Double, Double)] = []
        for run in runs {
            let items = run.map { tokens[$0] }
            if items.contains(where: { $0.kind == .word }) {
                let first = run.first!, last = run.last!
                let p = (0..<first).reversed().first(where: keptWord).map { tokens[$0].sourceEndMs }
                let n = (last + 1..<tokens.count).first(where: keptWord).map { tokens[$0].sourceStartMs }
                let ctx = Context(previousKeptEnd: p, nextKeptStart: n, sessionStart: items[0].sessionOffsetMs)
                let allFillers = items.allSatisfy { $0.kind == .word && $0.fillerTier == 1 }
                let range = allFillers
                    ? padFiller(items[0].sourceStartMs, items[items.count - 1].sourceEndMs, ctx)
                    : padNormal(items[0].sourceStartMs, items[items.count - 1].sourceEndMs, ctx)
                out.append(range)
            } else {
                for gap in items { out += tighten(gap.sourceStartMs, gap.sourceEndMs, present: present) }
            }
        }
        return merge(out)
    }

    /// Parts of `[a, b]` no slice covers.
    static func uncovered(_ a: Double, _ b: Double, slices: [Slice]) -> [(Double, Double)] {
        var gaps: [(Double, Double)] = []
        var cursor = a
        for s in slices.sorted(by: { $0.sourceStartMs < $1.sourceStartMs }) where s.sourceEndMs > a && s.sourceStartMs < b {
            if s.sourceStartMs > cursor { gaps.append((cursor, min(s.sourceStartMs, b))) }
            cursor = max(cursor, s.sourceEndMs)
        }
        if cursor < b { gaps.append((cursor, b)) }
        return gaps
    }

    /// Time the ranges would remove.
    static func removedDuration(_ slices: [Slice], _ ranges: [(Double, Double)]) -> Double {
        ranges.reduce(0) { total, r in
            total + (r.1 - r.0) - uncovered(r.0, r.1, slices: slices).reduce(0) { $0 + $1.1 - $1.0 }
        }
    }

    enum Change { case remove, trimHead(Double), trimTail(Double), split(Double, Double) }

    static func classify(_ slice: Slice, _ a: Double, _ b: Double) -> Change? {
        if b <= slice.sourceStartMs || a >= slice.sourceEndMs { return nil }
        let head = a <= slice.sourceStartMs || a - slice.sourceStartMs < minSliceMs
        let tail = b >= slice.sourceEndMs || slice.sourceEndMs - b < minSliceMs
        if head && tail { return .remove }
        if head { return .trimHead(b) }
        if tail { return .trimTail(a) }
        return .split(a, b)
    }

    /// Every slice would be removed.
    static func wouldRemoveAll(_ slices: [Slice], _ ranges: [(Double, Double)]) -> Bool {
        slices.allSatisfy { s in ranges.contains { if case .remove = classify(s, $0.0, $0.1) { return true } else { return false } } }
    }

    static func applyCuts(_ project: inout Project, _ ranges: [(Double, Double)]) {
        for r in ranges.sorted(by: { $0.0 > $1.0 }) {
            for i in project.slices.indices.reversed() {
                let s = project.slices[i]
                guard s.sourceStartMs < r.1 && s.sourceEndMs > r.0, let change = classify(s, r.0, r.1) else { continue }
                switch change {
                case .remove: project.slices.remove(at: i)
                case .trimHead(let b): project.slices[i].sourceStartMs = b
                case .trimTail(let a): project.slices[i].sourceEndMs = a
                case .split(let a, let b):
                    var right = s
                    right.id = UUID()
                    right.sourceStartMs = b
                    project.slices[i].sourceEndMs = a
                    project.slices.insert(right, at: i + 1)
                }
            }
        }
    }

    /// `removeNonPresentTimelineItmes`: zooms, layouts and masks entirely cut out are removed.
    static func removeNonPresentItems(_ project: inout Project) {
        let resolver = project.resolver
        func gone(_ start: Double, _ end: Double) -> Bool { !resolver.isSourceTimePresent(start) && !resolver.isSourceTimePresent(end) }
        project.zooms.removeAll { gone($0.startMs, $0.endMs) }
        project.cameraLayouts.removeAll { gone($0.startMs, $0.endMs) }
        project.masks.removeAll { gone($0.startMs, $0.endMs) }
    }

    public enum DeleteResult: Equatable { case nothing, wouldRemoveAll, removed(Double) }

    /// `deleteTokens`: cuts the present tokens out of the video.
    public static func delete(_ deleted: [TranscriptToken], tokens: [TranscriptToken], project: inout Project) -> DeleteResult {
        let present = deleted.filter { isPresent($0, in: project) }
        guard !present.isEmpty else { return .nothing }
        var ranges = cutRanges(tokens: tokens, deleted: present, project: project)
        if removedDuration(project.slices, ranges) <= 0 {
            let p = presentRanges(project)
            ranges = merge(present.flatMap { $0.kind == .gap ? intersect($0.sourceStartMs, $0.sourceEndMs, p) : [] })
        }
        if wouldRemoveAll(project.slices, ranges) { return .wouldRemoveAll }
        let removed = removedDuration(project.slices, ranges)
        guard removed > 0 else { return .nothing }
        applyCuts(&project, ranges)
        removeNonPresentItems(&project)
        return .removed(removed)
    }

    /// Brings `[a, b]` back, snapping to neighbours within 100 ms.
    public static func addBack(_ project: inout Project, _ a: Double, _ b: Double) {
        let duration = project.recording.durationMs
        for (x, y) in uncovered(a, b, slices: project.slices).reversed() {
            let prev = project.slices.last { $0.sourceEndMs <= x }
            let next = project.slices.first { $0.sourceStartMs >= y }
            let pe = prev?.sourceEndMs ?? 0, ns = next?.sourceStartMs ?? duration
            let x2 = x - pe <= 100 ? pe : x
            var y2 = ns - y <= 100 ? ns : y
            if y2 - x2 < 100 { y2 = min(ns, x2 + 100) }
            if y2 - x2 < 100 { continue }
            if x2 <= pe && y2 >= ns {
                // Bridges the hole: the neighbour is extended (both slices are kept).
                if let prev, let i = project.slices.firstIndex(where: { $0.id == prev.id }) {
                    project.slices[i].sourceEndMs = ns
                } else if let next, let j = project.slices.firstIndex(where: { $0.id == next.id }) {
                    project.slices[j].sourceStartMs = pe
                }
                continue
            }
            guard var template = prev ?? next else { continue }
            template.id = UUID()
            template.sourceStartMs = x2
            template.sourceEndMs = y2
            let index = project.slices.firstIndex { $0.sourceStartMs >= y2 } ?? project.slices.count
            project.slices.insert(template, at: index)
        }
    }

    /// `restoreTarget`: video back for cut words (40 ms of air) or cut pauses.
    public static func restore(_ target: [TranscriptToken], project: inout Project) {
        guard target.contains(where: { !isPresent($0, in: project) }) else { return }
        let words = target.filter { $0.kind == .word }
        if let first = words.first, let last = words.last, words.contains(where: { !isPresent($0, in: project) }) {
            addBack(&project, first.sourceStartMs - 40, last.sourceEndMs + 40)
        } else {
            for gap in target.filter({ $0.kind == .gap && !isPresent($0, in: project) }).sorted(by: { $0.sourceStartMs > $1.sourceStartMs }) {
                addBack(&project, gap.sourceStartMs, gap.sourceEndMs)
            }
        }
    }

    // MARK: Word edits

    /// Hides (or shows) the words from `i0` to `i1` in captions.
    public static func setHidden(_ words: [TranscriptWord], from i0: Int, to i1: Int, hidden: Bool) -> [TranscriptWord] {
        var out = words
        for i in min(i0, i1)...max(i0, i1) where out.indices.contains(i) { out[i].isHidden = hidden ? true : nil }
        return out
    }

    /// Replaces words `i0…i1` with `text`, sharing their time span by character length.
    public static func correct(_ words: [TranscriptWord], from i0: Int, to i1: Int, text: String) -> [TranscriptWord] {
        guard words.indices.contains(i0), words.indices.contains(i1), i0 <= i1 else { return words }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let replaced = Array(words[i0...i1])
        let start = replaced[0].startMs, end = replaced[replaced.count - 1].endMs
        let span = end - start
        let total = max(parts.reduce(0) { $0 + $1.count }, 1)
        let hidden = replaced.allSatisfy { $0.isHidden == true } ? true : nil
        let type = Set(replaced.map { $0.type ?? "" }).count == 1 ? replaced[0].type : nil
        var cursor = start
        var made: [TranscriptWord] = []
        for (k, part) in parts.enumerated() {
            let partEnd = k == parts.count - 1 ? end : (cursor + span * Double(part.count) / Double(total)).rounded()
            made.append(TranscriptWord(index: 0, startMs: cursor, endMs: partEnd, text: part, isHidden: hidden, type: type))
            cursor = partEnd
        }
        var out = words
        out.replaceSubrange(i0...i1, with: made)
        return SessionTranscript.normalized(out)
    }
}
