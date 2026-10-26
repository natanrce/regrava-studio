import CoreGraphics
import Foundation

extension SD {
    /// A face followed frame to frame on half-resolution luma by normalized template matching.
    ///
    /// Coordinates: `rect` is in video pixels; the template lives on the half frame and is a grid of
    /// `templateWidth × templateHeight` cells, each the mean of `unitPx × unitPx` half-frame pixels.
    final class FollowedFace {
        /// One sub-rectangle of the template grid (cell columns and rows).
        struct Part {
            let columns: Range<Int>
            let rows: Range<Int>
        }

        typealias Look = (unitPx: Int, template: [Float], width: Int, height: Int, offset: CGVector, deviation: Float)

        var rect: CGRect
        var velocity: CGVector
        var isVelocityKnown: Bool
        var timeMs: Double
        var lastFoundMs: Double
        var path: [(timeMs: Double, point: CGPoint)]
        var boxes: [(timeMs: Double, rect: CGRect)]
        /// Path points are `rect.origin + pathOffset`, so a re-anchored face keeps a continuous path.
        var pathOffset: CGVector
        var isLookChangedSinceSighting: Bool
        var unchangedUpToMs: Int
        let halfWidth: Int
        let halfHeight: Int
        var unitPx: Int
        var template: [Float]
        var templateWidth: Int
        var templateHeight: Int
        /// Video-pixel offset from `rect.origin` to the template's top-left cell.
        var templateOffset: CGVector
        var templateDeviation: Float
        /// The template as it was at the last sighting.
        var sightingLook: Look?
        var sightingCount: Int
        var missesSinceSighting: Int

        init?(rect: CGRect, in frame: HalfFrame, halfWidth: Int, halfHeight: Int) {
            self.boxes = []
            self.velocity = .zero
            self.isVelocityKnown = false
            self.pathOffset = .zero
            self.isLookChangedSinceSighting = false
            self.unitPx = 1
            self.template = []
            self.templateWidth = 0
            self.templateHeight = 0
            self.templateOffset = .zero
            self.templateDeviation = 0
            self.sightingLook = nil
            self.sightingCount = 1
            self.missesSinceSighting = 0
            self.rect = rect
            self.halfWidth = halfWidth
            self.halfHeight = halfHeight
            self.timeMs = frame.timeMs
            self.lastFoundMs = frame.timeMs
            self.unchangedUpToMs = Int(frame.timeMs.rounded(.up))
            self.path = [(frame.timeMs, rect.origin)]
            self.boxes = [(frame.timeMs, rect)]
            guard takeTemplate(in: frame) else { return nil }
            rememberSightingLook()
        }

        /// A copy that starts a fresh path at `other`'s current position and keeps its look.
        init(continuing other: FollowedFace) {
            self.rect = other.rect
            self.velocity = other.velocity
            self.isVelocityKnown = other.isVelocityKnown
            self.timeMs = other.timeMs
            self.lastFoundMs = other.lastFoundMs
            self.pathOffset = other.pathOffset
            self.path = [(other.timeMs, CGPoint(x: other.rect.minX + other.pathOffset.dx, y: other.rect.minY + other.pathOffset.dy))]
            self.boxes = []
            self.isLookChangedSinceSighting = false
            self.unchangedUpToMs = other.unchangedUpToMs
            self.halfWidth = other.halfWidth
            self.halfHeight = other.halfHeight
            self.unitPx = other.unitPx
            self.template = other.template
            self.templateWidth = other.templateWidth
            self.templateHeight = other.templateHeight
            self.templateOffset = other.templateOffset
            self.templateDeviation = other.templateDeviation
            self.sightingLook = other.sightingLook
            self.sightingCount = other.sightingCount
            self.missesSinceSighting = 0
        }

        /// The face's rect moved to the path point (of `along` followed by its own path) nearest in time to `atMs`;
        /// nil before the first point (with 1 ms tolerance).
        func rect(atMs: Double, along: [(timeMs: Double, point: CGPoint)]) -> CGRect? {
            var all = along
            all.append(contentsOf: path)
            guard let first = all.first, first.timeMs - 1 <= atMs else { return nil }
            var best = first
            for p in all.dropFirst() where abs(p.timeMs - atMs) < abs(best.timeMs - atMs) {
                best = p
            }
            return rect.offsetBy(dx: best.point.x - (rect.minX + pathOffset.dx), dy: best.point.y - (rect.minY + pathOffset.dy))
        }

        /// Samples the face's half-frame area into a zero-mean, unit-norm template grid of at most 24 cells
        /// along its longer side. Fails on areas under 4 half pixels, outside the frame or nearly flat.
        func takeTemplate(in frame: HalfFrame) -> Bool {
            let half = CGRect(x: rect.minX * 0.5, y: rect.minY * 0.5, width: rect.width * 0.5, height: rect.height * 0.5)
            let area = half.intersection(CGRect(x: 0, y: 0, width: Double(halfWidth), height: Double(halfHeight)))
            guard !area.isNull, area.width >= 4, area.height >= 4 else { return false }
            let unit = max(Int((max(area.width, area.height) / 24).rounded()), 1)
            let columns = max(Int(area.width) / unit, 4)
            let rows = max(Int(area.height) / unit, 4)
            let x0 = Int(area.minX.rounded())
            let y0 = Int(area.minY.rounded())
            guard x0 >= 0, y0 >= 0, x0 + columns * unit <= halfWidth, y0 + rows * unit <= halfHeight else { return false }
            var cells = [Float](repeating: 0, count: columns * rows)
            let scale = 1 / Float(unit * unit)
            frame.pixels.withUnsafeBufferPointer { px in
                for row in 0..<rows {
                    for column in 0..<columns {
                        var sum = 0
                        for y in (y0 + row * unit)..<(y0 + (row + 1) * unit) {
                            let line = y * halfWidth
                            for x in (x0 + column * unit)..<(x0 + (column + 1) * unit) { sum += Int(px[line + x]) }
                        }
                        cells[row * columns + column] = scale * Float(sum)
                    }
                }
            }
            var total: Float = 0
            for v in cells { total += v }
            let mean = total / Float(UInt(cells.count))
            var squares: Float = 0
            for i in cells.indices {
                let d = cells[i] - mean
                cells[i] = d
                squares += d * d
            }
            guard 4 <= squares / Float(UInt(cells.count)) else { return false }
            unitPx = unit
            templateDeviation = (squares / Float(UInt(cells.count))).squareRoot()
            let norm = squares.squareRoot()
            template = cells.map { $0 / norm }
            templateWidth = columns
            templateHeight = rows
            templateOffset = CGVector(dx: Double(x0 * 2) - rect.minX, dy: Double(y0 * 2) - rect.minY)
            return true
        }

        func rememberSightingLook() {
            sightingLook = (unitPx, template, templateWidth, templateHeight, templateOffset, templateDeviation)
        }

        /// Looks for the face again with its sighting look around its last rect; on success the face
        /// restarts there (fresh path and boxes, velocity unknown).
        func revive(at frame: HalfFrame) -> Bool {
            if let look = sightingLook {
                unitPx = look.unitPx
                template = look.template
                templateWidth = look.width
                templateHeight = look.height
                templateOffset = look.offset
                templateDeviation = look.deviation
            }
            let whole = Part(columns: 0..<templateWidth, rows: 0..<templateHeight)
            guard let found = search(whole, in: frame, elapsedMs: 0, slackX: 8, slackY: 8, isUniqueOnly: false, minScore: 0.8, displacement: nil) else {
                return false
            }
            rect = found.rect
            velocity = .zero
            isVelocityKnown = false
            timeMs = frame.timeMs
            lastFoundMs = frame.timeMs
            path = [(frame.timeMs, CGPoint(x: found.rect.minX + pathOffset.dx, y: rect.minY + pathOffset.dy))]
            boxes = [(frame.timeMs, found.rect)]
            unchangedUpToMs = Int(frame.timeMs.rounded(.up))
            isLookChangedSinceSighting = false
            return true
        }

        /// Normalized cross-correlation of the template part over a window around the predicted position.
        ///
        /// The prediction is the current rect moved by `displacement`, or by `velocity × elapsedMs` when no
        /// displacement is given (then the window also widens by the predicted motion). The window spans
        /// `slackX`/`slackY` half pixels (at least 2 and 3 cells). A candidate whose pixels are too flat scores 0.
        /// Acceptance: `minScore`, else 0.75 (0.65 for templates of 16 cells or more) for the whole template,
        /// else 0.8. `isUniqueOnly` also rejects a match when any position at least half the part away scores
        /// within 0.1 of it. The best position is refined by a parabola through its neighbours (±0.5 cell).
        func search(_ part: Part, in frame: HalfFrame, elapsedMs: Double, slackX: Int, slackY: Int, isUniqueOnly: Bool,
                    minScore: Float?, displacement: CGVector?) -> (rect: CGRect, score: Float)? {
            let partWidth = part.columns.upperBound - part.columns.lowerBound
            let partHeight = part.rows.upperBound - part.rows.lowerBound
            let isWhole = partWidth == templateWidth && partHeight == templateHeight
            let count = partWidth * partHeight
            var sub = [Float]()
            sub.reserveCapacity(max(count, 0))
            for row in part.rows {
                for column in part.columns { sub.append(template[row * templateWidth + column]) }
            }
            if !isWhole {
                guard !sub.isEmpty else { return nil }
                var total: Float = 0
                for v in sub { total += v }
                let mean = total / Float(UInt(sub.count))
                var squares: Float = 0
                for i in sub.indices {
                    let d = sub[i] - mean
                    sub[i] = d
                    squares += d * d
                }
                guard squares > 1e-6 else { return nil }
                let norm = squares.squareRoot()
                for i in sub.indices { sub[i] = sub[i] / norm }
            }

            let shift: CGVector
            if let displacement { shift = displacement } else {
                shift = CGVector(dx: elapsedMs * velocity.dx, dy: elapsedMs * velocity.dy)
            }
            let moved = rect.offsetBy(dx: shift.dx, dy: shift.dy)
            let unit = unitPx
            let originX = Int(((moved.minX + templateOffset.dx) * 0.5).rounded())
            let baseX = originX + part.columns.lowerBound * unit
            let originY = Int(((moved.minY + templateOffset.dy) * 0.5).rounded())
            let baseY = originY + part.rows.lowerBound * unit
            var extraX = 0.0
            var extraY = 0.0
            if displacement == nil {
                extraX = abs(shift.dx) / Double(unit * 2)
                extraY = abs(shift.dy) / Double(unit * 2)
            }
            let reachX = Int(extraX.rounded(.up)) + max((unit + slackX / 2 - 1) / unit, 2)
            let reachY = Int(extraY.rounded(.up)) + max((unit + slackY / 2 - 1) / unit, 3)
            let lowX = max(-reachX, Int((-Double(baseX) / Double(unit)).rounded(.up)))
            let highX = min((halfWidth - partWidth * unit - baseX) / unit, reachX)
            let lowY = max(-reachY, Int((-Double(baseY) / Double(unit)).rounded(.up)))
            let highY = min((halfHeight - partHeight * unit - baseY) / unit, reachY)
            guard highX >= lowX, highY >= lowY else { return nil }

            let areaWidth = partWidth + highX - lowX
            let areaHeight = partHeight + highY - lowY
            let areaX = baseX + lowX * unit
            let areaY = baseY + lowY * unit
            var area = [Float](repeating: 0, count: areaWidth * areaHeight)
            let scale = 1 / Float(unit * unit)
            frame.pixels.withUnsafeBufferPointer { px in
                for row in 0..<areaHeight {
                    for column in 0..<areaWidth {
                        var sum = 0
                        for y in (areaY + row * unit)..<(areaY + (row + 1) * unit) {
                            let line = y * halfWidth
                            for x in (areaX + column * unit)..<(areaX + (column + 1) * unit) { sum += Int(px[line + x]) }
                        }
                        area[row * areaWidth + column] = scale * Float(sum)
                    }
                }
            }

            let deviation = sightingLook == nil ? templateDeviation : sightingLook!.deviation
            let minDeviation = Float.maximum(deviation * 0.2, 2)
            let gridWidth = highX - lowX + 1
            var scores = [Float](repeating: -1, count: gridWidth * (highY - lowY + 1))
            let floorVariance = minDeviation * minDeviation * Float(count)
            var best: Float = -1
            var bestX = 0
            var bestY = 0
            for dy in lowY...highY {
                for dx in lowX...highX {
                    var dot: Float = 0
                    var squares: Float = 0
                    var sum: Float = 0
                    for r in 0..<partHeight {
                        let a0 = (r + dy - lowY) * areaWidth + (dx - lowX)
                        let s0 = r * partWidth
                        for c in 0..<partWidth {
                            let a = area[a0 + c]
                            dot += a * sub[s0 + c]
                            sum += a
                            squares += a * a
                        }
                    }
                    let variance = squares - (sum * sum) / Float(count)
                    var score: Float = 0
                    if floorVariance < variance { score = dot / variance.squareRoot() }
                    scores[(dy - lowY) * gridWidth + (dx - lowX)] = score
                    if best < score {
                        best = score
                        bestX = dx
                        bestY = dy
                    }
                }
            }

            if let minScore {
                guard minScore <= best else { return nil }
            } else if isUniqueOnly || !isWhole {
                guard !(best < 0.8) else { return nil }
            } else {
                let threshold: Float = max(templateHeight, templateWidth) < 16 ? 0.75 : 0.65
                guard threshold <= best else { return nil }
            }
            if isUniqueOnly {
                let halfPartWidth = partWidth / 2
                let halfPartHeight = partHeight >> 1
                let rival = best + -0.1
                for dy in lowY...highY {
                    for dx in lowX...highX {
                        if abs(dx - bestX) >= halfPartWidth || abs(dy - bestY) >= halfPartHeight {
                            if rival < scores[(dy - lowY) * gridWidth + (dx - lowX)] { return nil }
                        }
                    }
                }
            }

            func refine(_ before: Float, _ after: Float) -> Double {
                let curvature = (before - (best + best)) + after
                guard curvature < 0 else { return 0 }
                let v = ((before - after) * 0.5) / curvature
                return Double(v < 0.5 ? Float.maximum(v, -0.5) : 0.5)
            }
            func score(_ x: Int, _ y: Int) -> Float { scores[(y - lowY) * gridWidth + (x - lowX)] }
            func inGrid(_ x: Int, _ y: Int) -> Bool { x >= lowX && highX >= x && y >= lowY && highY >= y }

            var offsetX = 0.0
            let hasLeft = inGrid(bestX - 1, bestY)
            let left: Float = hasLeft ? score(bestX - 1, bestY) : 0
            if inGrid(bestX + 1, bestY), hasLeft { offsetX = refine(left, score(bestX + 1, bestY)) }
            var offsetY = 0.0
            let hasUp = inGrid(bestX, bestY - 1)
            let up: Float = hasUp ? score(bestX, bestY - 1) : 0
            if inGrid(bestX, bestY + 1), hasUp { offsetY = refine(up, score(bestX, bestY + 1)) }

            let x = (offsetX + Double(bestX)) * Double(unit) + Double(baseX - part.columns.lowerBound * unit)
            let y = (offsetY + Double(bestY)) * Double(unit) + Double(baseY - part.rows.lowerBound * unit)
            let found = CGRect(x: (x + x) - templateOffset.dx, y: (y + y) - templateOffset.dy, width: rect.width, height: rect.height)
            return (found, best)
        }

        /// Whether the face still matches its sighting look near its current rect (always true without one).
        func looksAsWhenSeen(in frame: HalfFrame) -> Bool {
            guard let look = sightingLook else { return true }
            let saved = (unitPx, template, templateWidth, templateHeight, templateOffset, templateDeviation)
            unitPx = look.unitPx
            template = look.template
            templateWidth = look.width
            templateHeight = look.height
            templateOffset = look.offset
            templateDeviation = look.deviation
            let found = search(Part(columns: 0..<look.width, rows: 0..<look.height), in: frame, elapsedMs: 0, slackX: 8, slackY: 8,
                               isUniqueOnly: false, minScore: 0.65, displacement: nil) != nil
            (unitPx, template, templateWidth, templateHeight, templateOffset, templateDeviation) = saved
            return found
        }

        /// Moves the face onto a new sighting: the path continues (offset absorbs the jump) and the
        /// template is retaken there; if that fails the face keeps its previous rect and template.
        func reanchor(to newRect: CGRect, in frame: HalfFrame) {
            isLookChangedSinceSighting = false
            sightingCount += 1
            missesSinceSighting = 0
            boxes.append((frame.timeMs, newRect))
            let oldRect = rect
            let oldOffset = pathOffset
            let saved = (unitPx, template, templateWidth, templateHeight, templateOffset, templateDeviation)
            pathOffset.dx += oldRect.minX - newRect.minX
            pathOffset.dy += rect.minY - newRect.minY
            rect = newRect
            if takeTemplate(in: frame) {
                rememberSightingLook()
            } else {
                rect = oldRect
                pathOffset = oldOffset
                (unitPx, template, templateWidth, templateHeight, templateOffset, templateDeviation) = saved
            }
        }

        /// Keeps the face where it is (its pixels did not change) up to `atMs`.
        func hold(atMs: Double, unchangedUpToMs: Int) {
            if abs(atMs - lastFoundMs) > 100 { velocity = .zero }
            timeMs = atMs
            path.append((atMs, CGPoint(x: rect.minX + pathOffset.dx, y: rect.minY + pathOffset.dy)))
            self.unchangedUpToMs = unchangedUpToMs
        }

        /// Finds the face in the next frame: first along its velocity, then along the measured scroll,
        /// then with wider windows, then (for larger templates) by its visible parts.
        func follow(to frame: HalfFrame, scrollDy: CGFloat?) -> Bool {
            let whole = Part(columns: 0..<templateWidth, rows: 0..<templateHeight)
            let elapsed = frame.timeMs - timeMs
            var isMoving = false
            var found: (rect: CGRect, score: Float)?
            var isWholeMatch = true
            if isVelocityKnown {
                isMoving = hypot(velocity.dx, velocity.dy) >= 0.03
                found = search(whole, in: frame, elapsedMs: elapsed, slackX: 8, slackY: 24, isUniqueOnly: false, minScore: nil, displacement: nil)
            }
            if found == nil {
                var tryWide = true
                if let scrollDy {
                    if scrollDy != 0 || !isVelocityKnown {
                        found = search(whole, in: frame, elapsedMs: elapsed, slackX: 8, slackY: 24, isUniqueOnly: false, minScore: nil,
                                       displacement: CGVector(dx: 0, dy: scrollDy))
                    } else {
                        tryWide = false
                    }
                }
                if found == nil, tryWide, !isVelocityKnown {
                    found = search(whole, in: frame, elapsedMs: elapsed, slackX: 24, slackY: 80, isUniqueOnly: false, minScore: nil, displacement: nil)
                }
                if found == nil, isMoving {
                    found = search(whole, in: frame, elapsedMs: elapsed, slackX: 48, slackY: 400, isUniqueOnly: true, minScore: nil, displacement: nil)
                }
                if found == nil, max(templateHeight, templateWidth) >= 16 {
                    for part in visibleParts() {
                        if let r = search(part, in: frame, elapsedMs: elapsed, slackX: 8, slackY: 24, isUniqueOnly: false, minScore: nil, displacement: nil) {
                            found = r
                            isWholeMatch = false
                            break
                        }
                    }
                }
            }
            guard let found else { return false }
            if elapsed != 0 {
                var vx = (found.rect.minX - rect.minX) / elapsed
                var vy = (found.rect.minY - rect.minY) / elapsed
                if isVelocityKnown {
                    vx = (vx + velocity.dx) * 0.5
                    vy = (vy + velocity.dy) * 0.5
                }
                velocity = CGVector(dx: vx, dy: vy)
                isVelocityKnown = true
            }
            rect = found.rect
            timeMs = frame.timeMs
            lastFoundMs = frame.timeMs
            path.append((frame.timeMs, CGPoint(x: found.rect.minX + pathOffset.dx, y: rect.minY + pathOffset.dy)))
            unchangedUpToMs = Int(frame.timeMs.rounded(.up))
            if found.score < 0.85, isWholeMatch {
                _ = takeTemplate(in: frame)
                isLookChangedSinceSighting = true
            }
            return true
        }

        /// Halves (or the trailing half and third, against the motion) of the template used when the
        /// whole face is partly covered; only parts of more than 2×2 cells when moving.
        func visibleParts() -> [Part] {
            let w = templateWidth
            let h = templateHeight
            let halves = [Part(columns: 0..<w, rows: 0..<(h / 2)), Part(columns: 0..<w, rows: (h / 2)..<h),
                          Part(columns: 0..<(w >> 1), rows: 0..<h), Part(columns: (w >> 1)..<w, rows: 0..<h)]
            if hypot(velocity.dx, velocity.dy) < 0.03 { return halves }
            if path.count < 2 { return halves }
            var vx = velocity.dx
            var vy = velocity.dy
            if !(path[0].timeMs <= path[path.count - 1].timeMs) {
                vx = -vx
                vy = -vy
            }
            let candidates: [Part]
            if abs(vx) <= abs(vy) {
                if vy >= 0 {
                    candidates = [Part(columns: 0..<w, rows: 0..<(h / 2)), Part(columns: 0..<w, rows: 0..<(h / 3))]
                } else {
                    candidates = [Part(columns: 0..<w, rows: (h / 2)..<h), Part(columns: 0..<w, rows: ((2 * h) / 3)..<h)]
                }
            } else if vx >= 0 {
                candidates = [Part(columns: 0..<(w >> 1), rows: 0..<h), Part(columns: 0..<(w / 3), rows: 0..<h)]
            } else {
                candidates = [Part(columns: (w >> 1)..<w, rows: 0..<h), Part(columns: ((2 * w) / 3)..<w, rows: 0..<h)]
            }
            return candidates.filter { $0.columns.count > 2 && $0.rows.count > 2 }
        }

        /// Extends the path backwards along the velocity, in 60 fps steps, for at most the time the face
        /// needs to travel its own size (and at most 1200 ms), until it leaves `frameRect`.
        func extrapolateBack(frameRect: CGRect) -> (startMs: Double, path: [(timeMs: Double, point: CGPoint)]) {
            let speed = hypot(velocity.dx, velocity.dy)
            guard speed >= 0.03 else { return (timeMs, []) }
            let reach = max(rect.width, rect.height) / speed
            var limit = 1200.0
            if !(reach >= 1200) {
                guard reach > 0 else { return (timeMs - 0, []) }
                limit = reach
            }
            var back = 0.0
            var points: [(timeMs: Double, point: CGPoint)] = []
            while true {
                let next = back + 16.666666666666668
                back = next < limit ? next : limit
                let r = rect.offsetBy(dx: -(velocity.dx * back), dy: -(velocity.dy * back))
                points.append((timeMs - back, CGPoint(x: r.minX + pathOffset.dx, y: r.minY + pathOffset.dy)))
                let inside = r.intersects(frameRect)
                if !(next < limit) || !inside { break }
            }
            return (timeMs - back, points)
        }
    }
}
