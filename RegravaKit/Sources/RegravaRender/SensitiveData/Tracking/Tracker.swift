import CoreGraphics
import Foundation

// Tracking: turns the findings of every read into items with a lifetime (start, end) and a path
// of keyframes. A finding continues an active item when it has the same key (or nearly the same
// key, for long keys) and sits where the item is expected to be after the measured scroll; an item
// that is not found again ends once its pixels changed and no visible text supports it any more.

extension SD {
    /// Area of a rect; a null rect has no area.
    static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// Intersection over union of two rects; the union is taken as at least 1 square pixel.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = area(a.intersection(b))
        var union = area(a) + area(b) - intersection
        if union <= 1 { union = 1 }
        return intersection / union
    }

    /// True when at least 60% of `rect` lies inside the region a read covered (the face region for
    /// faces, the text region otherwise).
    static func isCovered(_ rect: CGRect, by observation: Observation, kind: String) -> Bool {
        let region = kind == "face" ? observation.faceRegion : observation.region
        let covered = area(region.intersection(rect))
        return area(rect) * 0.6 <= covered
    }

    /// Levenshtein distance between `a` and `b`, or `limit + 1` as soon as it must exceed `limit`.
    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if limit < abs(a.count - b.count) { return limit + 1 }
        var previous = Array(0 ... b.count)
        for i in 0 ..< a.count {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            var rowMinimum = current[0]
            for j in 0 ..< b.count {
                let cost = a[i] == b[j] ? 0 : 1
                current[j + 1] = min(previous[j] + cost, min(current[j] + 1, previous[j + 1] + 1))
                rowMinimum = min(current[j + 1], rowMinimum)
            }
            if limit < rowMinimum { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    /// When an item first appeared, as estimated by `Tracker.startMs(of:foundAt:)`.
    /// Field names (the layout is start time, optional (absent, present) pair, typed flag).
    struct StartEstimate {
        let startMs: Int
        /// The last read without the item and the first read with it, when the start is bracketed by reads.
        let evidence: (absentMs: Int, presentMs: Int)?
        /// The text appeared gradually (typed) rather than all at once.
        let isTyped: Bool
    }
}

extension SD.TrackedItem {
    /// Velocity (px per ms) between keyframes `index` and `index + 1`, when both exist, are at
    /// different times and the motion is faster than 0.03 px/ms.
    func velocity(at index: Int) -> CGVector? {
        guard index >= 0, index + 1 < keyframes.count else { return nil }
        let a = keyframes[index]
        let b = keyframes[index + 1]
        let dt = b.timeMs - a.timeMs
        guard dt >= 1 else { return nil }
        let duration = CGFloat(dt)
        let dx = (b.rect.minX - a.rect.minX) / duration
        let dy = (b.rect.minY - a.rect.minY) / duration
        guard hypot(dx, dy) > 0.03 else { return nil }
        return CGVector(dx: dx, dy: dy)
    }

    /// True when no keyframe is more than 3 px (in x or y) away from the first one.
    var isStill: Bool {
        for keyframe in keyframes {
            if abs(keyframe.rect.minX - keyframes[0].rect.minX) > 3 { return false }
            if abs(keyframe.rect.minY - keyframes[0].rect.minY) > 3 { return false }
        }
        return true
    }
}

extension SD {
    final class Tracker {
        let observations: [Observation]
        let timeline: ChangeTimeline
        let grid: TileGrid
        let options: Options
        let durationMs: Int
        var nextId: Int
        /// Indices of `observations`, grouped by read time.
        let observationIndicesByTimeMs: [Int: [Int]]

        init(observations: [Observation], timeline: ChangeTimeline, grid: TileGrid, options: Options, durationMs: Int) {
            self.observations = observations
            self.timeline = timeline
            self.grid = grid
            self.options = options
            self.durationMs = durationMs
            nextId = 1
            observationIndicesByTimeMs = Dictionary(grouping: observations.indices, by: { observations[$0].timeMs })
        }

        private var frame: CGRect {
            CGRect(x: 0, y: 0, width: CGFloat(grid.widthPx), height: CGFloat(grid.heightPx))
        }

        // MARK: Following the measured scroll

        /// Follows a rect through consecutive change samples using the vertical shift measured for
        /// its stripe. Small shifts are held back until enough of the rect's tiles changed to confirm them.
        struct MotionWalk {
            let tracker: Tracker
            let stripe: Int
            var heldPx: CGFloat = 0
            var heldSinceMs: Int = 0
            var heldTiles: Set<Int> = []
            var lastShiftMoved: Bool = false

            init(tracker: Tracker, stripe: Int) {
                self.tracker = tracker
                self.stripe = stripe
            }

            /// The vertical motion (px, positive = content moved up) of `rect` in `sample`: 0 when it
            /// did not move (or the motion is still held back), nil when the rect's pixels changed
            /// without a measured shift.
            mutating func step(_ rect: CGRect, in sample: ChangeSample) -> CGFloat? {
                if sample.isEverything {
                    heldPx = 0
                    heldTiles = []
                    lastShiftMoved = false
                    return 0
                }
                let tiles = tracker.grid.tiles(in: rect)
                let shifts = sample.stripeShiftsPx
                if shifts.isEmpty || shifts[stripe] == Int16.min {
                    for tile in tiles where sample.changedTiles[tile >> 6] & (1 << UInt64(tile & 63)) != 0 {
                        return nil
                    }
                    heldPx = 0
                    heldTiles = []
                    lastShiftMoved = false
                    return 0
                }
                let shiftPx = CGFloat(shifts[stripe]) / 8
                lastShiftMoved = shiftPx != 0
                if shiftPx == 0 {
                    heldPx = 0
                    heldTiles = []
                    return 0
                }
                if heldPx == 0 && heldTiles.isEmpty { heldSinceMs = sample.timeMs }
                var changed: [Int] = []
                for tile in tiles where sample.changedTiles[tile >> 6] & (1 << UInt64(tile & 63)) != 0 {
                    changed.append(tile)
                }
                for tile in changed { heldTiles.insert(tile) }
                let doubled = heldTiles.count * 2
                if tiles.isEmpty ? doubled > 0 : doubled >= tiles.count {
                    let total = shiftPx + heldPx
                    heldPx = 0
                    heldTiles = []
                    return total
                }
                heldPx = shiftPx + heldPx
                if abs(sample.timeMs - heldSinceMs) >= 301 {
                    heldPx = 0
                    heldTiles = []
                }
                return 0
            }
        }

        /// Where `rect`, seen at `fromMs`, is at `toMs` after following the measured scroll (either
        /// direction). Nil when its pixels changed in a way the scroll does not explain.
        func moved(_ rect: CGRect, fromMs: Int, toMs: Int) -> CGRect? {
            var walk = MotionWalk(tracker: self, stripe: grid.stripe(ofX: rect.midX))
            var moving = rect
            let samples = timeline.samples
            if fromMs < toMs {
                var index = timeline.firstIndex(after: fromMs)
                while index < samples.count {
                    let sample = samples[index]
                    if toMs < sample.timeMs { break }
                    guard let dy = walk.step(moving, in: sample) else { return nil }
                    moving = moving.offsetBy(dx: 0, dy: -dy)
                    index += 1
                }
            } else {
                var index = timeline.firstIndex(after: fromMs)
                while index >= 1 {
                    let sample = samples[index - 1]
                    if toMs >= sample.timeMs { break }
                    guard let dy = walk.step(moving, in: sample) else { return nil }
                    moving = moving.offsetBy(dx: 0, dy: dy)
                    index -= 1
                }
            }
            return moving
        }

        // MARK: Reads

        /// The read made at exactly `atMs` that covers `rect`.
        func read(atMs: Int, covering rect: CGRect, kind: String) -> Observation? {
            guard let indices = observationIndicesByTimeMs[atMs] else { return nil }
            for index in indices {
                let observation = observations[index]
                if SD.isCovered(rect, by: observation, kind: kind) { return observation }
            }
            return nil
        }

        /// Overlap tests shared by the line checks: the line overlaps the finding vertically by at
        /// least half the smaller height and horizontally at all.
        private static func lineOverlaps(_ line: RecognizedLine, _ finding: Finding) -> Bool {
            let overlapY = min(line.rect.maxY, finding.rect.maxY) - max(line.rect.minY, finding.rect.minY)
            if min(line.rect.height, finding.rect.height) * 0.5 > overlapY { return false }
            if !(finding.rect.minX < line.rect.maxX) { return false }
            if !(line.rect.minX < finding.rect.maxX) { return false }
            return true
        }

        /// True when a line of `observation`, at the finding's place, holds the beginning of the
        /// finding's text: either its first 4 characters somewhere in the line, or the line ending
        /// with a shorter prefix of it (being typed), in both cases near the finding's left edge.
        func hasTypedPrefix(of finding: Finding, in observation: Observation) -> Bool {
            let key = finding.key
            return observation.lines.contains { line in
                guard Self.lineOverlaps(line, finding) else { return false }
                let lineCharacters = Array(line.key)
                let tolerance = max(finding.rect.height + finding.rect.height, finding.rect.width * 0.5)
                let keyCharacters = Array(key)
                let lineCount = lineCharacters.count
                if keyCharacters.count >= 4 && lineCount >= 4 {
                    let probe = Array(keyCharacters.prefix(4))
                    for start in 0 ... (lineCount - 4) {
                        let window = Array(lineCharacters[start ..< start + 4])
                        if window == probe {
                            let x = line.rect.minX + line.rect.width * CGFloat(start) / CGFloat(lineCount)
                            if abs(x - finding.rect.minX) <= tolerance { return true }
                        }
                    }
                }
                let firstLength = lineCount >= 4 ? 2 : 1
                guard keyCharacters.count > firstLength else { return false }
                for length in firstLength ..< keyCharacters.count {
                    if line.key.reversed().starts(with: key.prefix(length).reversed()) {
                        let x = line.rect.minX + line.rect.width * CGFloat(lineCount - length) / CGFloat(lineCount)
                        if abs(x - finding.rect.minX) <= tolerance { return true }
                    }
                }
                return false
            }
        }

        /// True when a line of `observation` at the finding's place is long (4 characters or more)
        /// or starts well away from the finding's left edge. Faces always count.
        func hasLongLine(at finding: Finding, in observation: Observation) -> Bool {
            if finding.kind == "face" { return true }
            for line in observation.lines {
                guard Self.lineOverlaps(line, finding) else { continue }
                if line.key.count >= 4 { return true }
                let distance = abs(line.rect.minX - finding.rect.minX)
                let tolerance = max(finding.rect.height + finding.rect.height, finding.rect.width * 0.5)
                if !(tolerance >= distance) { return true }
            }
            return false
        }

        // MARK: Start estimate

        /// When the finding read in `observations[foundAt]` first appeared: walks back through the
        /// scroll (an item that scrolled in starts when it entered the view) and through earlier
        /// reads of the same place, until the tiles under it changed.
        func startMs(of finding: Finding, foundAt index: Int) -> StartEstimate {
            let observation = observations[index]
            let foundMs = observation.timeMs
            let frame = frame
            var walk = MotionWalk(tracker: self, stripe: grid.stripe(ofX: finding.rect.midX))
            let samples = timeline.samples
            var rect = finding.rect
            var movedAtMs: Int?
            var sampleIndex = timeline.firstIndex(after: foundMs)
            while sampleIndex >= 1 {
                let sample = samples[sampleIndex - 1]
                if (movedAtMs ?? foundMs) - sample.timeMs > 500 { break }
                guard let dy = walk.step(rect, in: sample) else { break }
                if dy == 0 {
                    if walk.lastShiftMoved && movedAtMs != nil { movedAtMs = sample.timeMs }
                } else {
                    rect = rect.offsetBy(dx: 0, dy: dy)
                    let visible = SD.area(rect.intersection(frame))
                    let isOffScreen = rect.isNull ? !(visible >= 0) : visible < SD.area(rect) * 0.2
                    if isOffScreen {
                        return StartEstimate(startMs: max(0, sample.timeMs - options.sampleMs), evidence: nil, isTyped: false)
                    }
                    movedAtMs = sample.timeMs
                }
                sampleIndex -= 1
            }

            if let movedAtMs {
                // The item scrolled into place: look for it in earlier reads at its scrolled position.
                var laterMs = movedAtMs - options.sampleMs
                let tiles = grid.tiles(in: rect)
                let shifted = Finding(kind: finding.kind, text: finding.text, key: finding.key, rect: rect)
                guard index != 0 else { return StartEstimate(startMs: 0, evidence: nil, isTyped: false) }
                var isAnchored = false
                var isTyped = false
                var earlierIndex = index - 1
                while earlierIndex >= 0 {
                    let earlier = observations[earlierIndex]
                    earlierIndex -= 1
                    if earlier.timeMs >= laterMs { continue }
                    if !SD.isCovered(rect, by: earlier, kind: shifted.kind) { continue }
                    if !shifted.key.isEmpty && shifted.kind != "face" && hasTypedPrefix(of: shifted, in: earlier) {
                        if earlierIndex < 0 { return StartEstimate(startMs: 0, evidence: nil, isTyped: true) }
                        isTyped = true
                        isAnchored = true
                        laterMs = earlier.timeMs
                        continue
                    }
                    if !hasLongLine(at: shifted, in: earlier) && laterMs - earlier.timeMs < 1001
                        && !timeline.hasSuddenChange(in: tiles, afterMs: earlier.timeMs, upToMs: laterMs) {
                        isTyped = true
                        continue
                    }
                    if let change = timeline.changes(inAnyOf: tiles, afterMs: earlier.timeMs, upToMs: laterMs) {
                        return StartEstimate(startMs: max(0, change.firstMs - options.sampleMs), evidence: nil, isTyped: isTyped)
                    }
                    if !isAnchored { return StartEstimate(startMs: laterMs, evidence: nil, isTyped: isTyped) }
                    laterMs = earlier.timeMs
                }
                return StartEstimate(startMs: 0, evidence: nil, isTyped: isTyped)
            }

            // The item did not move: look back through earlier reads of the same place.
            let tiles = grid.tiles(in: finding.rect)
            guard index != 0 else { return StartEstimate(startMs: 0, evidence: nil, isTyped: false) }
            var laterMs = foundMs
            var isTyped = false
            var earlierIndex = index - 1
            while earlierIndex >= 0 {
                let earlier = observations[earlierIndex]
                earlierIndex -= 1
                if earlier.timeMs >= laterMs { continue }
                if !SD.isCovered(finding.rect, by: earlier, kind: finding.kind) { continue }
                if !finding.key.isEmpty && finding.kind != "face" && hasTypedPrefix(of: finding, in: earlier) {
                    if earlierIndex < 0 { return StartEstimate(startMs: 0, evidence: nil, isTyped: true) }
                    isTyped = true
                    laterMs = earlier.timeMs
                    continue
                }
                if !hasLongLine(at: finding, in: earlier) && laterMs - earlier.timeMs < 1001
                    && !timeline.hasSuddenChange(in: tiles, afterMs: earlier.timeMs, upToMs: laterMs) {
                    isTyped = true
                    continue
                }
                if let change = timeline.changes(inAnyOf: tiles, afterMs: earlier.timeMs, upToMs: laterMs) {
                    return StartEstimate(startMs: max(0, change.firstMs - options.sampleMs),
                                         evidence: (absentMs: earlier.timeMs, presentMs: laterMs), isTyped: isTyped)
                }
                laterMs = earlier.timeMs
            }
            return StartEstimate(startMs: 0, evidence: nil, isTyped: isTyped)
        }

        // MARK: Looks

        /// Tile signatures of the read that last saw `item` and of `observation`, per tile under
        /// the item's last rect, when both reads stored that tile.
        private func signaturePairs(_ item: TrackedItem, _ seen: Observation, _ observation: Observation,
                                    _ body: (Int, ArraySlice<UInt8>, ArraySlice<UInt8>) -> Void) {
            for tile in grid.tiles(in: item.lastSeenRect) {
                let a = (tile - seen.firstTile) * 16
                if a < 0 { continue }
                if seen.tileSignatures.count < a + 16 { continue }
                let b = (tile - observation.firstTile) * 16
                if b < 0 { continue }
                if observation.tileSignatures.count < b + 16 { continue }
                body(tile, seen.tileSignatures[a ..< a + 16], observation.tileSignatures[b ..< b + 16])
            }
        }

        /// True when two tile signatures match once each tile's mean is removed: every block differs
        /// by at most the change threshold.
        static func isSameLook(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>, threshold16: Int) -> Bool {
            var difference = 0
            for k in 0 ..< 16 { difference += Int(b[b.startIndex + k]) - Int(a[a.startIndex + k]) }
            for k in 0 ..< 16 {
                let value = difference + Int(a[a.startIndex + k]) * 16 - Int(b[b.startIndex + k]) * 16
                if !(threshold16 >= value && value >= -threshold16) { return false }
            }
            return true
        }

        /// True when at least 70% of the tiles under the item still look as they did when the item
        /// was last seen.
        func looksAsWhenSeen(_ item: TrackedItem, in observation: Observation) -> Bool {
            guard let seen = read(atMs: item.lastSeenMs, covering: item.lastSeenRect, kind: item.kind) else { return false }
            let tiles = grid.tiles(in: item.lastSeenRect)
            let threshold16 = options.changeThreshold * 16
            var same: [Int] = []
            signaturePairs(item, seen, observation) { tile, then, now in
                if Self.isSameLook(then, now, threshold16: threshold16) { same.append(tile) }
            }
            return same.count * 10 >= tiles.count * 7
        }

        /// True when the textured tiles under the item correlate (r ≥ 0.9) with how they looked when
        /// the item was last seen in at least 70% of cases: the same content under other lighting
        /// (dimmed, highlighted).
        func looksAsWhenSeenUnderOtherLight(_ item: TrackedItem, in observation: Observation) -> Bool {
            guard let seen = read(atMs: item.lastSeenMs, covering: item.lastSeenRect, kind: item.kind) else { return false }
            guard !grid.tiles(in: item.lastSeenRect).isEmpty else { return false }
            var textured = 0
            var correlated = 0
            signaturePairs(item, seen, observation) { _, then, now in
                let x = then.map { Double($0) }
                let y = now.map { Double($0) }
                var sumX = 0.0
                for value in x { sumX += value }
                let count = Double(x.count)
                let meanX = sumX / count
                var sumY = 0.0
                for value in y { sumY += value }
                let meanY = sumY / Double(y.count)
                var sxy = 0.0
                var syy = 0.0
                var sxx = 0.0
                for k in 0 ..< x.count {
                    let dx = x[k] - meanX
                    let dy = y[k] - meanY
                    sxy += dx * dy
                    sxx += dx * dx
                    syy += dy * dy
                }
                if !(count * 9 < sxx) { return }
                textured += 1
                if syy <= count { return }
                let r = sxy / (sxx * syy).squareRoot()
                if r < 0.9 { return }
                correlated += 1
            }
            guard textured >= 1 else { return false }
            return correlated * 10 >= textured * 7
        }

        // MARK: Coming back

        /// Items for the times after `item` ended when its place looked exactly as when it was last
        /// seen again (the content came back, e.g. after a popup closed). At most 50.
        func revivals(of item: TrackedItem) -> [TrackedItem] {
            let tiles = grid.tiles(in: item.lastSeenRect)
            guard let seen = read(atMs: item.lastSeenMs, covering: item.lastSeenRect, kind: item.kind) else { return [] }
            var looks: [ArraySlice<UInt8>] = []
            for tile in tiles {
                let a = (tile - seen.firstTile) * 16
                guard a >= 0, seen.tileSignatures.count >= a + 16 else { return [] }
                looks.append(seen.tileSignatures[a ..< a + 16])
            }
            guard !looks.isEmpty else { return [] }
            var current: [ArraySlice<UInt8>?] = []
            for (i, tile) in tiles.enumerated() {
                if timeline.changes(inAnyOf: [tile], afterMs: item.lastSeenMs, upToMs: item.endMs) == nil {
                    current.append(looks[i])
                } else {
                    current.append(timeline.signature(ofTile: tile, atMs: item.endMs))
                }
            }
            var result: [TrackedItem] = []
            let threshold16 = options.changeThreshold * 16
            let samples = timeline.samples
            var isBack = false
            var backAtMs = 0

            func addRevival(backAtMs: Int, goneAtMs: Int?) {
                let revival = TrackedItem(id: nextId, kind: item.kind, text: item.text, key: item.key,
                                          startMs: max(0, backAtMs - options.sampleMs), endMs: 0, lastSeenMs: backAtMs,
                                          lastSeenRect: item.lastSeenRect, keyframes: [(timeMs: backAtMs, rect: item.lastSeenRect)],
                                          endIfGoneMs: 0)
                nextId += 1
                if let goneAtMs {
                    revival.endMs = goneAtMs
                    revival.startEvidence = (absentMs: backAtMs - 1, presentMs: backAtMs)
                    revival.endEvidence = (presentMs: backAtMs, absentMs: goneAtMs)
                } else {
                    revival.endMs = durationMs
                    revival.startEvidence = (absentMs: backAtMs - 1, presentMs: backAtMs)
                }
                result.append(revival)
            }

            var sampleIndex = timeline.firstIndex(after: item.endMs)
            while sampleIndex < samples.count {
                if result.count > 49 { break }
                let sample = samples[sampleIndex]
                sampleIndex += 1
                var changed = false
                for (i, tile) in tiles.enumerated()
                where sample.isEverything || sample.changedTiles[tile >> 6] & (1 << UInt64(tile & 63)) != 0 {
                    current[i] = sample.signature(ofTile: tile)
                    changed = true
                }
                if !changed { continue }
                var isSame = true
                for i in 0 ..< current.count {
                    _ = looks[i]
                    guard let now = current[i], Self.isSameLook(now, looks[i], threshold16: threshold16) else {
                        isSame = false
                        break
                    }
                }
                if isSame {
                    if !isBack { backAtMs = sample.timeMs }
                    isBack = true
                } else {
                    if isBack { addRevival(backAtMs: backAtMs, goneAtMs: sample.timeMs) }
                    backAtMs = 0
                    isBack = false
                }
            }
            if isBack { addRevival(backAtMs: backAtMs, goneAtMs: nil) }
            return result
        }

        /// The parts of `item`'s lifetime not already covered by an item of `items` with the same
        /// (or nearly the same) key at the same place. Parts shorter than one sample are dropped.
        func uncoveredParts(of item: TrackedItem, among items: [TrackedItem]) -> [TrackedItem] {
            var covering: [TrackedItem] = []
            for other in items {
                guard other.startMs < item.endMs, item.startMs < other.endMs else { continue }
                if other.key != item.key {
                    guard min(other.key.count, item.key.count) > 9 else { continue }
                    guard SD.editDistance(Array(other.key), Array(item.key), limit: 2) < 3 else { continue }
                }
                guard other.keyframes.contains(where: { SD.intersectionOverUnion($0.rect, item.lastSeenRect) > 0.5 }) else { continue }
                covering.append(other)
            }
            let spans = covering.map { (startMs: $0.startMs, endMs: $0.endMs) }.sorted { $0.startMs < $1.startMs }
            guard !spans.isEmpty else { return [item] }
            var fromMs = item.startMs
            var parts: [TrackedItem] = []

            func addPart(upToMs: Int) {
                guard upToMs - fromMs >= options.sampleMs else { return }
                let part = TrackedItem(id: nextId, kind: item.kind, text: item.text, key: item.key, startMs: fromMs,
                                       endMs: 0, lastSeenMs: fromMs, lastSeenRect: item.lastSeenRect,
                                       keyframes: [(timeMs: fromMs, rect: item.lastSeenRect)], endIfGoneMs: 0)
                nextId += 1
                part.endMs = upToMs
                if fromMs == item.startMs { part.startEvidence = item.startEvidence }
                if upToMs == item.endMs { part.endEvidence = item.endEvidence }
                parts.append(part)
            }

            for span in spans {
                if fromMs >= span.endMs { continue }
                addPart(upToMs: min(span.startMs, item.endMs))
                fromMs = max(fromMs, span.endMs)
                if fromMs >= item.endMs { return parts }
            }
            addPart(upToMs: item.endMs)
            return parts
        }

        // MARK: Motion

        /// Re-plots the item's keyframes along the measured scroll: backwards from its first keyframe
        /// to its start, and forwards from each keyframe to the next (the last one up to 3 s past its
        /// end), extending the end while the moving rect stays on screen. Returns whether it moved.
        func followMotion(_ item: TrackedItem) -> Bool {
            let samples = timeline.samples
            let first = item.keyframes[0]
            let stripe = grid.stripe(ofX: first.rect.midX)
            var walk = MotionWalk(tracker: self, stripe: stripe)
            var rect = first.rect
            var back: [(timeMs: Int, rect: CGRect)] = []
            var hasMoved = false
            var sampleIndex = timeline.firstIndex(after: first.timeMs) - 1
            while sampleIndex >= 0 {
                let sample = samples[sampleIndex]
                if item.startMs >= sample.timeMs { break }
                guard let dy = walk.step(rect, in: sample) else { break }
                if dy != 0 {
                    back.append((timeMs: sample.timeMs, rect: rect))
                    rect = rect.offsetBy(dx: 0, dy: dy)
                    hasMoved = true
                }
                sampleIndex -= 1
            }
            if !back.isEmpty { back.append((timeMs: item.startMs, rect: rect)) }
            var path = Array(back.reversed())
            let keyframes = item.keyframes
            let frame = frame
            for (n, keyframe) in keyframes.enumerated() {
                path.append(keyframe)
                let limitMs = n == keyframes.count - 1 ? min(item.endMs + 3000, durationMs) : keyframes[n + 1].timeMs
                var forward = MotionWalk(tracker: self, stripe: stripe)
                var moving = keyframe.rect
                var lastMoveMs = keyframe.timeMs
                var index = timeline.firstIndex(after: keyframe.timeMs)
                while index < samples.count {
                    let sample = samples[index]
                    if sample.timeMs >= limitMs { break }
                    // Past the end, keep going only while the motion goes on.
                    if item.endMs < sample.timeMs && sample.timeMs - lastMoveMs > 500 { break }
                    guard let dy = forward.step(moving, in: sample) else { break }
                    if dy != 0 {
                        lastMoveMs = sample.timeMs
                        moving = moving.offsetBy(dx: 0, dy: -dy)
                        path.append((timeMs: sample.timeMs, rect: moving))
                        if item.endMs < sample.timeMs && moving.intersects(frame) { item.endMs = sample.timeMs }
                        hasMoved = true
                    }
                    index += 1
                }
            }
            if hasMoved { item.keyframes = path }
            return hasMoved
        }

        /// When the item would leave the screen, moving from `keyframe` with `velocity` (forward or
        /// backward in time): the time its rect crosses a frame edge.
        func offScreenMs(from keyframe: (timeMs: Int, rect: CGRect), velocity: CGVector, isForward: Bool) -> Int? {
            let sign: CGFloat = isForward ? 1 : -1
            let vy = velocity.dy * sign
            let rect = keyframe.rect
            var times: [CGFloat] = []
            if vy < 0 { times.append(rect.maxY / -vy) }
            let vx = velocity.dx * sign
            if vy > 0 { times.append((CGFloat(grid.heightPx) - rect.minY) / vy) }
            if vx < 0 { times.append(rect.maxX / -vx) }
            if vx > 0 { times.append((CGFloat(grid.widthPx) - rect.minX) / vx) }
            guard var soonest = times.first else { return nil }
            for time in times.dropFirst() where time < soonest { soonest = time }
            return keyframe.timeMs + Int(sign * soonest)
        }

        /// Extends a moving item (not followed by measured scroll) along its first and last velocity:
        /// the start back to when it entered the screen and the end on to when it leaves (at most 3 s
        /// each way), adding a keyframe at the new start and end.
        func extrapolateMotion(_ item: TrackedItem) {
            guard item.keyframes.count >= 2 else { return }
            if let velocity = item.velocity(at: 0),
               let enteredMs = offScreenMs(from: item.keyframes[0], velocity: velocity, isForward: false) {
                item.startMs = max(0, max(item.startMs - 3000, min(enteredMs, item.startMs)))
            }
            if let velocity = item.velocity(at: item.keyframes.count - 2),
               let leftMs = offScreenMs(from: item.keyframes[item.keyframes.count - 1], velocity: velocity, isForward: true) {
                item.endMs = min(max(leftMs, item.endMs), min(item.endMs + 3000, durationMs))
            }
            let frame = frame
            let first = item.keyframes[0]
            if item.startMs < first.timeMs {
                var rect = first.rect
                if item.velocity(at: 0) != nil {
                    let next = item.keyframes[1]
                    let dt = next.timeMs - first.timeMs
                    if dt != 0 {
                        let f = CGFloat(item.startMs - first.timeMs) / CGFloat(dt)
                        rect = first.rect.offsetBy(dx: f * (next.rect.minX - first.rect.minX), dy: f * (next.rect.minY - first.rect.minY))
                        if rect.intersects(frame) { rect = rect.intersection(frame) }
                    }
                }
                item.keyframes.insert((timeMs: item.startMs, rect: rect), at: 0)
            }
            let last = item.keyframes[item.keyframes.count - 1]
            if last.timeMs < item.endMs {
                var rect = last.rect
                let previousIndex = item.keyframes.count - 2
                if item.velocity(at: previousIndex) != nil {
                    let previous = item.keyframes[previousIndex]
                    let dt = previous.timeMs - last.timeMs
                    if dt != 0 {
                        let f = CGFloat(item.endMs - last.timeMs) / CGFloat(dt)
                        rect = last.rect.offsetBy(dx: f * (previous.rect.minX - last.rect.minX), dy: f * (previous.rect.minY - last.rect.minY))
                        if rect.intersects(frame) { rect = rect.intersection(frame) }
                    }
                }
                item.keyframes.append((timeMs: item.endMs, rect: rect))
            }
        }

        // MARK: track()

        /// Runs every read in order and returns all items, sorted by start (then id).
        func track() -> [TrackedItem] {
            var active: [TrackedItem] = []
            var ended: [TrackedItem] = []
            let frame = frame
            for (offset, observation) in observations.enumerated() {
                let findings = observation.findings
                var claimed = [Bool](repeating: false, count: findings.count)
                var stillActive: [TrackedItem] = []
                for item in active {
                    let last = item.keyframes[item.keyframes.count - 1]
                    let movedRect = moved(last.rect, fromMs: last.timeMs, toMs: observation.timeMs)
                    let predicted = movedRect ?? item.keyframes[item.keyframes.count - 1].rect
                    guard SD.isCovered(predicted, by: observation, kind: item.kind) else {
                        stillActive.append(item)
                        continue
                    }
                    let tiles = grid.tiles(in: item.keyframes[item.keyframes.count - 1].rect)
                    let change = timeline.changes(inAnyOf: tiles, afterMs: item.lastSeenMs, upToMs: observation.timeMs)
                    let isFace = item.kind == "face"
                    let isUnchangedOrUnmoved = change == nil || movedRect == nil

                    // The closest finding with the item's key at the expected place.
                    var best: Int?
                    var bestDistance = CGFloat.infinity
                    for (j, finding) in findings.enumerated() where !claimed[j] {
                        if finding.key != item.key {
                            guard min(finding.key.count, item.key.count) >= 10 else { continue }
                            guard SD.editDistance(Array(finding.key), Array(item.key), limit: 2) <= 2 else { continue }
                        }
                        let isNear: Bool
                        if isFace {
                            let distance = hypot(finding.rect.midX - predicted.midX, finding.rect.midY - predicted.midY)
                            isNear = distance < max(finding.rect.width, predicted.width) * 0.5
                        } else {
                            isNear = SD.intersectionOverUnion(finding.rect, predicted) > 0.2
                                || (abs(finding.rect.minX - predicted.minX) < predicted.height
                                    && abs(finding.rect.minY - predicted.minY) < predicted.height * 0.5)
                        }
                        if isUnchangedOrUnmoved {
                            if !isNear { continue }
                        } else if !isNear && movedRect! == item.keyframes[item.keyframes.count - 1].rect {
                            continue
                        }
                        if isFace {
                            let ratio = finding.rect.width / CGFloat.maximum(predicted.width, 1)
                            let overlap = SD.intersectionOverUnion(finding.rect, predicted)
                            guard overlap >= 0.3, ratio > 0.7, ratio < 1.4 else { continue }
                        }
                        let distance = hypot(finding.rect.midX - predicted.midX, finding.rect.midY - predicted.midY)
                        if distance < bestDistance {
                            best = j
                            bestDistance = distance
                        }
                    }

                    // Otherwise a long piece of the item's key read at the expected place.
                    var matched: (index: Int, byKey: Bool)?
                    if let best {
                        matched = (best, true)
                    } else {
                        for (j, finding) in findings.enumerated() where !claimed[j] {
                            guard finding.key.count > 9, item.key.range(of: finding.key) != nil else { continue }
                            let inside = SD.area(finding.rect.intersection(predicted))
                            let isInside = finding.rect.isNull ? inside >= 0 : !(SD.area(finding.rect) * 0.7 > inside)
                            if isInside {
                                matched = (j, false)
                                break
                            }
                        }
                    }

                    if let matched {
                        claimed[matched.index] = true
                        let finding = findings[matched.index]
                        var rect = matched.byKey
                            ? finding.rect
                            : predicted.offsetBy(dx: 0, dy: finding.rect.midY - predicted.midY)
                        let lastRect = item.keyframes[item.keyframes.count - 1].rect
                        if isFace {
                            let side = max(rect.width, lastRect.width * 0.9)
                            rect = CGRect(x: rect.midX - side * 0.5, y: rect.midY - side * 0.5, width: side, height: side)
                        }
                        let positionTolerance: CGFloat
                        if isFace {
                            let scaled = lastRect.width * 0.0625
                            positionTolerance = scaled >= 4 ? scaled : 4
                        } else {
                            positionTolerance = 2
                        }
                        let sizeTolerance: CGFloat = isFace ? lastRect.width * 0.125 : 4
                        if change != nil {
                            let shift = abs(rect.minX - lastRect.minX) + abs(rect.minY - lastRect.minY)
                            if positionTolerance < shift || !(sizeTolerance >= abs(rect.width - lastRect.width)) {
                                item.keyframes.append((timeMs: observation.timeMs, rect: rect))
                            }
                        }
                        if item.text.count < finding.text.count { item.text = finding.text }
                        item.lastSeenMs = observation.timeMs
                        item.lastSeenRect = rect
                        item.missedAtMs = nil
                        stillActive.append(item)
                        continue
                    }

                    // Not found again.
                    guard let change else {
                        stillActive.append(item)
                        continue
                    }
                    if predicted == item.keyframes[item.keyframes.count - 1].rect
                        && looksAsWhenSeenUnderOtherLight(item, in: observation) {
                        stillActive.append(item)
                        continue
                    }
                    let isMoving = predicted != item.keyframes[item.keyframes.count - 1].rect
                        || item.velocity(at: item.keyframes.count - 2) != nil
                    let isStillVisible: Bool
                    if isFace {
                        isStillVisible = looksAsWhenSeen(item, in: observation)
                    } else {
                        isStillVisible = observation.lines.contains { line in
                            guard line.rect.intersects(predicted) else { return false }
                            let characters = Array(item.key)
                            let width = min(characters.count, 6)
                            guard width != 0 else { return false }
                            for start in 0 ... (characters.count - width) {
                                let piece = String(characters[start ..< start + width])
                                if line.key.range(of: piece) != nil { return true }
                            }
                            return false
                        }
                    }
                    if (isMoving && !isFace) || isStillVisible {
                        if let missedAtMs = item.missedAtMs {
                            item.endMs = item.keyframes.count > 1 ? max(missedAtMs, item.endIfGoneMs) : item.endIfGoneMs
                            if item.isStill { item.endEvidence = (presentMs: item.lastSeenMs, absentMs: missedAtMs) }
                            ended.append(item)
                            continue
                        }
                        item.missedAtMs = observation.timeMs
                        item.endIfGoneMs = change.lastMs
                        let lastKeyframe = item.keyframes[item.keyframes.count - 1]
                        if predicted == lastKeyframe.rect {
                            guard let velocity = item.velocity(at: item.keyframes.count - 2) else {
                                stillActive.append(item)
                                continue
                            }
                            let lastNow = item.keyframes[item.keyframes.count - 1]
                            let dt = CGFloat(observation.timeMs - lastNow.timeMs)
                            let rect = lastNow.rect.offsetBy(dx: velocity.dx * dt, dy: velocity.dy * dt)
                            if rect.intersects(frame) {
                                item.keyframes.append((timeMs: observation.timeMs, rect: rect.intersection(frame)))
                            }
                        } else if predicted.intersects(frame) {
                            item.keyframes.append((timeMs: observation.timeMs, rect: predicted))
                        }
                        stillActive.append(item)
                        continue
                    }
                    let absentMs = item.missedAtMs ?? observation.timeMs
                    item.endMs = item.missedAtMs == nil ? change.lastMs : item.endIfGoneMs
                    item.endEvidence = (presentMs: item.lastSeenMs, absentMs: absentMs)
                    ended.append(item)
                }

                active = stillActive
                for (j, finding) in findings.enumerated() where !claimed[j] {
                    let estimate = startMs(of: finding, foundAt: offset)
                    let item = TrackedItem(id: nextId, kind: finding.kind, text: finding.text, key: finding.key,
                                           startMs: estimate.startMs, endMs: 0, lastSeenMs: observation.timeMs,
                                           lastSeenRect: finding.rect, keyframes: [(timeMs: observation.timeMs, rect: finding.rect)],
                                           endIfGoneMs: 0, startEvidence: estimate.evidence, isTyped: estimate.isTyped)
                    nextId += 1
                    active.append(item)
                }
            }

            for item in active {
                if let missedAtMs = item.missedAtMs {
                    item.endMs = max(missedAtMs, item.endIfGoneMs)
                    if item.isStill { item.endEvidence = (presentMs: item.lastSeenMs, absentMs: missedAtMs) }
                } else {
                    item.endMs = durationMs
                }
            }
            var all = ended
            all.append(contentsOf: active)
            for revival in ended.flatMap({ revivals(of: $0) }) {
                all.append(contentsOf: uncoveredParts(of: revival, among: all))
            }
            for item in all where !followMotion(item) && item.kind != "face" {
                extrapolateMotion(item)
            }
            for item in all {
                // Cut the path after the first keyframe that left the screen for good.
                let keyframes = item.keyframes
                var count = keyframes.count
                while count > 0 && !keyframes[count - 1].rect.intersects(frame) { count -= 1 }
                guard count > 0 else { continue }
                if count < item.keyframes.count && item.startMs < item.keyframes[count].timeMs {
                    item.endMs = item.keyframes[count].timeMs
                    item.keyframes.removeSubrange((count + 1) ..< item.keyframes.count)
                }
            }
            return all.sorted { $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs }
        }
    }
}
