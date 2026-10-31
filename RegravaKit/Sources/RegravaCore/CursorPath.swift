import Foundation

// Smoothed cursor planner.
//
// A spring chases the recorded path, which on its own lags behind the real cursor, so a click
// would be drawn before the smoothed cursor reaches the button. The planner fixes that: for each
// group of "sync points" (clicks, drags, cursor image changes) it lets the spring target run a
// little ahead of time ("lead") and, if needed, temporarily stiffens the spring ("speed"), choosing
// the smallest adjustment that brings the drawn cursor within a few points of the real position
// at every sync point. The resulting motion is simulated once in 1 ms steps and stored.

/// Planner settings.
public struct CursorPathSettings: Sendable {
    public var groupGapMs: Double = 100
    public var mergeGapMs: Double = 400
    public var maxLeadMs: Double = 600
    public var approachWindowMs: Double = 1500
    public var compressionWindowMs: Double = 400
    public var maxCompressionRate: Double = 1.4
    public var leadDecayPerMs: Double = 0.35
    public var speedLevels: [Double] = [1, 1.25, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10, 13, 16, 20, 25, 32]
    public var speedBlendInMs: Double = 250
    public var speedBlendOutMs: Double = 300
    public var acceptedErrorRatio: Double = 0.75

    public init() {}
}

public enum CursorSyncReason: String, Sendable {
    case click, drag, hover, cursorImage

    /// Accepted distance from the recorded position, in points.
    public var tolerancePoints: Double {
        switch self {
        case .click, .drag: return 2
        case .hover: return 4
        case .cursorImage: return 6
        }
    }
}

public struct CursorSyncPoint: Sendable {
    public var timeMs: Double
    public var reason: CursorSyncReason
    public var tolerance: Double

    public init(timeMs: Double, reason: CursorSyncReason, tolerance: Double) {
        self.timeMs = timeMs
        self.reason = reason
        self.tolerance = tolerance
    }
}

public struct CursorPathPoint: Sendable {
    public var timeMs: Double
    public var position: Vec2

    public init(timeMs: Double, position: Vec2) {
        self.timeMs = timeMs
        self.position = position
    }
}

public struct TimeRange: Sendable, Hashable {
    public var startMs: Double
    public var endMs: Double

    public init(startMs: Double, endMs: Double) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Index of the first element whose key equals `value`, otherwise of the last element whose key
/// is below it; nil when every key is above.
func floorSearch(count: Int, value: Double, key: (Int) -> Double) -> Int? {
    var low = 0
    var high = count
    while low < high {
        let mid = (low + high) >> 1
        if key(mid) < value { low = mid + 1 } else { high = mid }
    }
    if low < count && key(low) == value { return low }
    return low > 0 ? low - 1 : nil
}

/// Whether the keys never decrease (false with a NaN key).
func isAscending(count: Int, key: (Int) -> Double) -> Bool {
    count < 2 || (1..<count).allSatisfy { key($0 - 1) <= key($0) }
}

/// Indices, in order, of the elements whose key lies in `[low, high]`; binary-searched when
/// `ascending` (see `isAscending`), filtered otherwise.
func indices(count: Int, ascending: Bool, from low: Double, through high: Double, key: (Int) -> Double) -> [Int] {
    guard ascending else { return (0..<count).filter { key($0) >= low && key($0) <= high } }
    let first = (lastSearch(count: count, while: { key($0) < low }) ?? -1) + 1
    let end = (lastSearch(count: count, while: { key($0) <= high }) ?? -1) + 1
    return Array(first..<max(first, end))
}

/// Index of the first element whose key is >= `value`.
func ceilSearch(count: Int, value: Double, key: (Int) -> Double) -> Int? {
    var low = 0
    var high = count
    while low < high {
        let mid = (low + high) >> 1
        if key(mid) >= value { high = mid } else { low = mid + 1 }
    }
    return low < count ? low : nil
}

/// Index of the last element satisfying `predicate`, for a predicate that holds on a prefix of
/// the elements and fails on the rest; nil when it holds on none.
func lastSearch(count: Int, while predicate: (Int) -> Bool) -> Int? {
    var low = 0
    var high = count
    while low < high {
        let mid = (low + high) >> 1
        if predicate(mid) { low = mid + 1 } else { high = mid }
    }
    return low > 0 ? low - 1 : nil
}

/// Gap above which two recorded samples are not interpolated.
let cursorSampleGapMs = 40.0
/// Tiny time offset used for instantaneous lead changes.
let leadStepMs = 0.001

// MARK: - Recorded path

final class RecordedCursorPath {
    let points: [CursorPathPoint]
    let movingRanges: [TimeRange]

    init(points: [CursorPathPoint]) {
        self.points = points
        var ranges: [TimeRange] = []
        if points.count > 1 {
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                if a.position == b.position { continue }
                let start = b.timeMs - a.timeMs <= cursorSampleGapMs ? a.timeMs : b.timeMs
                if let last = ranges.last, last.endMs >= start {
                    ranges[ranges.count - 1].endMs = max(last.endMs, b.timeMs)
                } else {
                    ranges.append(TimeRange(startMs: start, endMs: max(b.timeMs, start + 0.000001)))
                }
            }
        }
        movingRanges = ranges
    }

    var startMs: Double { points.first?.timeMs ?? 0 }

    private func pointIndex(_ t: Double) -> Int {
        floorSearch(count: points.count, value: t) { points[$0].timeMs } ?? -1
    }

    func position(at t: Double) -> Vec2 {
        let i = pointIndex(t)
        guard i >= 0 else { return points.first?.position ?? .zero }
        let a = points[i]
        guard i + 1 < points.count else { return a.position }
        let b = points[i + 1]
        if b.timeMs - a.timeMs > cursorSampleGapMs || b.timeMs == a.timeMs { return a.position }
        let f = (t - a.timeMs) / (b.timeMs - a.timeMs)
        return a.position.lerp(to: b.position, f)
    }

    private func rangeIndex(_ t: Double) -> Int? {
        floorSearch(count: movingRanges.count, value: t) { movingRanges[$0].startMs }
    }

    func isStill(between a: Double, and b: Double) -> Bool {
        if b < a { return isStill(between: b, and: a) }
        guard let i = rangeIndex(b) else { return true }
        return movingRanges[i].endMs <= a
    }

    func lastRest(endingBy t: Double) -> TimeRange? {
        guard let i = rangeIndex(t) else { return nil }
        let range = movingRanges[i]
        let start = i > 0 ? movingRanges[i - 1].endMs : -Double.infinity
        return TimeRange(startMs: start, endMs: range.startMs)
    }
}

// MARK: - Lead and speed curves

struct LeadCurve {
    struct Knot { var timeMs: Double; var leadMs: Double }
    var knots: [Knot] = []
    var cutTimesMs: [Double] = []

    mutating func add(_ timeMs: Double, _ leadMs: Double) {
        // Descending knots cannot be produced by the planner.
        if let last = knots.last, timeMs < last.timeMs { return }
        knots.append(Knot(timeMs: timeMs, leadMs: leadMs))
    }

    func planned(at t: Double) -> Double {
        guard let i = floorSearch(count: knots.count, value: t, key: { knots[$0].timeMs }) else { return 0 }
        // Like the hinted lookup, use the last knot at or before t.
        var index = i
        while index + 1 < knots.count && knots[index + 1].timeMs <= t { index += 1 }
        let a = knots[index]
        guard index + 1 < knots.count else { return a.leadMs }
        let b = knots[index + 1]
        if b.timeMs == a.timeMs { return a.leadMs }
        return a.leadMs + (b.leadMs - a.leadMs) * (t - a.timeMs) / (b.timeMs - a.timeMs)
    }

    func at(_ t: Double) -> Double {
        let lead = planned(at: t)
        if lead <= 0 || cutTimesMs.isEmpty { return max(0, lead) }
        guard let i = ceilSearch(count: cutTimesMs.count, value: t + 1e-9, key: { cutTimesMs[$0] }) else { return lead }
        return min(lead, cutTimesMs[i] - t)
    }
}

struct SpeedBump {
    var rampInStartMs: Double
    var fullStartMs: Double
    var fullEndMs: Double
    var rampOutEndMs: Double
    var speed: Double

    var logSpeed: Double { log(speed) }

    func logSpeed(at t: Double) -> Double {
        if t < fullStartMs {
            let span = fullStartMs - rampInStartMs
            return span <= 0 ? logSpeed : logSpeed * (t - rampInStartMs) / span
        }
        if t <= fullEndMs { return logSpeed }
        let span = rampOutEndMs - fullEndMs
        return span <= 0 ? 0 : logSpeed * (rampOutEndMs - t) / span
    }
}

struct SpeedCurve {
    var bumps: [SpeedBump] = []
    var longestBumpMs: Double = 0

    mutating func add(_ bump: SpeedBump) {
        guard bump.speed > 1 else { return }
        // Kept ordered by ramp-in start, after any bumps starting at the same time.
        let at = (lastSearch(count: bumps.count, while: { bumps[$0].rampInStartMs <= bump.rampInStartMs }) ?? -1) + 1
        bumps.insert(bump, at: at)
        longestBumpMs = max(longestBumpMs, bump.rampOutEndMs - bump.rampInStartMs)
    }

    func at(_ t: Double) -> Double {
        if bumps.isEmpty { return 1 }
        var best = 0.0
        var i = floorSearch(count: bumps.count, value: t) { bumps[$0].rampInStartMs } ?? -1
        while i >= 0 {
            let bump = bumps[i]
            if bump.rampInStartMs < t - longestBumpMs { break }
            if bump.rampOutEndMs > t { best = max(best, bump.logSpeed(at: t)) }
            i -= 1
        }
        return exp(best)
    }
}

// MARK: - Spring simulation

struct CursorState {
    var x: Double
    var y: Double
    var velocityX: Double
    var velocityY: Double

    static func resting(at p: Vec2) -> CursorState { CursorState(x: p.x, y: p.y, velocityX: 0, velocityY: 0) }
}

/// Snap distance / velocity of the cursor simulation.
private let cursorSettlePrecision = 0.01
/// Speed is re-evaluated every 4 ms.
private let speedBucketMs = 4.0

final class CursorSimulation {
    let path: RecordedCursorPath
    let spring: SpringConfig
    let instantRanges: [TimeRange]
    /// The ranges are in order and apart, so the last one starting at or before an instant is
    /// the only one that can contain it.
    private let instantRangesOrdered: Bool

    init(path: RecordedCursorPath, spring: SpringConfig, instantRanges: [TimeRange]) {
        self.path = path
        self.spring = spring
        self.instantRanges = instantRanges
        instantRangesOrdered = instantRanges.allSatisfy { $0.startMs <= $0.endMs }
            && zip(instantRanges, instantRanges.dropFirst()).allSatisfy { $0.endMs <= $1.startMs }
    }

    var lagMs: Double { spring.damping / spring.stiffness * 1000 }

    func target(lead: LeadCurve, at t: Double) -> Vec2 {
        path.position(at: t + lead.at(t))
    }

    func isInstant(_ t: Double) -> Bool {
        guard instantRangesOrdered else { return instantRanges.contains { t >= $0.startMs && t < $0.endMs } }
        guard let i = lastSearch(count: instantRanges.count, while: { t >= instantRanges[$0].startMs }) else { return false }
        return t < instantRanges[i].endMs
    }

    func run(
        lead: LeadCurve,
        speed: SpeedCurve,
        from: Double,
        to: Double,
        state: CursorState,
        onWholeMs: ((Double, Double, Double) -> Void)? = nil
    ) -> CursorState {
        var x = state.x, y = state.y, vx = state.velocityX, vy = state.velocityY
        let mass = spring.mass
        let hasInstantRanges = !instantRanges.isEmpty
        var current = from
        var bucket = Double.nan
        var stiffness = 0.0, damping = 0.0, omega = 0.0, critical = 0.0
        while current < to {
            let next = min(to, floor(current) + 1)
            let stepMs = next - current
            let target = self.target(lead: lead, at: next)
            if mass == 0 || (hasInstantRanges && isInstant(next)) {
                x = target.x; y = target.y; vx = 0; vy = 0
            } else if !(x == target.x && y == target.y && vx == 0 && vy == 0) {
                let currentBucket = floor(next / speedBucketMs) * speedBucketMs
                if currentBucket != bucket {
                    bucket = currentBucket
                    let s = speed.at(currentBucket)
                    stiffness = spring.stiffness * s * s
                    damping = spring.damping * s
                    omega = (stiffness / mass).squareRoot()
                    critical = max(damping, 2 * (mass * stiffness).squareRoot())
                }
                let h = stepMs / 1000
                let dx = target.x - x
                let dy = target.y - y
                let dampingX = spring.clampOvershoot && vx * dx > 0 && abs(vx) > abs(dx) * omega ? critical : damping
                let dampingY = spring.clampOvershoot && vy * dy > 0 && abs(vy) > abs(dy) * omega ? critical : damping
                vx += (dx * stiffness - vx * dampingX) / mass * h
                vy += (dy * stiffness - vy * dampingY) / mass * h
                x += vx * h
                y += vy * h
                if abs(vx) < cursorSettlePrecision && abs(x - target.x) < cursorSettlePrecision { x = target.x; vx = 0 }
                if abs(vy) < cursorSettlePrecision && abs(y - target.y) < cursorSettlePrecision { y = target.y; vy = 0 }
            }
            current = next
            if let onWholeMs, current == floor(current) { onWholeMs(current, x, y) }
        }
        return CursorState(x: x, y: y, velocityX: vx, velocityY: vy)
    }
}

// MARK: - Per-group choice

struct SyncGroup {
    var startMs: Double
    var endMs: Double
    var points: [CursorSyncPoint]
}

struct LeadChoice {
    var leadMs: Double
    var speed: Double
    var errorRatio: Double
    var endState: CursorState
    var leadKnots: [(Double, Double)]
    var speedBump: SpeedBump?

    var endLeadMs: Double { leadKnots.last?.1 ?? 0 }

    func commit(to lead: inout LeadCurve, speed curve: inout SpeedCurve) {
        for (t, l) in leadKnots { lead.add(t, l) }
        if let speedBump { curve.add(speedBump) }
    }
}

/// How lead decays after an anchor: instantly when the cursor is still, otherwise at
/// `leadDecayPerMs`.
func leadDecayKnots(path: RecordedCursorPath, anchorMs: Double, anchorLeadMs: Double, settings: CursorPathSettings) -> [(Double, Double)] {
    if anchorLeadMs <= 0 { return [(anchorMs, 0)] }
    if path.isStill(between: anchorMs, and: anchorMs + anchorLeadMs) {
        return [(anchorMs, anchorLeadMs), (anchorMs + leadStepMs, 0)]
    }
    return [(anchorMs, anchorLeadMs), (anchorMs + anchorLeadMs / settings.leadDecayPerMs, 0)]
}

struct PlanContext {
    var anchorMs: Double
    var anchorLeadMs: Double
    var anchorState: CursorState
    var lead: LeadCurve
    var speed: SpeedCurve
}

final class SyncGroupPlanner {
    let path: RecordedCursorPath
    let simulation: CursorSimulation
    let settings: CursorPathSettings
    let group: SyncGroup
    let context: PlanContext
    let windowStartMs: Double
    private var committedStates: [CursorState]?

    init(path: RecordedCursorPath, simulation: CursorSimulation, settings: CursorPathSettings, group: SyncGroup, context: PlanContext) {
        self.path = path
        self.simulation = simulation
        self.settings = settings
        self.group = group
        self.context = context
        windowStartMs = floor(max(context.anchorMs, group.startMs - settings.approachWindowMs - settings.maxLeadMs))
    }

    func choose() -> LeadChoice {
        let levels = settings.speedLevels
        var cache: [Int: LeadChoice] = [:]
        func choice(_ level: Int) -> LeadChoice {
            if let cached = cache[level] { return cached }
            let result = chooseLead(speed: levels[level])
            cache[level] = result
            return result
        }
        let first = choice(0)
        if first.errorRatio <= settings.acceptedErrorRatio { return first }
        var low = 0
        var high = levels.count - 1
        if choice(high).errorRatio > settings.acceptedErrorRatio {
            // Reduces in insertion order (levels 0, last): keep the first minimum.
            return [first, choice(high)].reduce(first) { $1.errorRatio < $0.errorRatio ? $1 : $0 }
        }
        while high - low > 1 {
            let mid = (low + high) >> 1
            if choice(mid).errorRatio <= settings.acceptedErrorRatio { high = mid } else { low = mid }
        }
        return choice(high)
    }

    private func chooseLead(speed: Double) -> LeadChoice {
        let accepted = settings.acceptedErrorRatio
        let baseLag = simulation.lagMs / speed
        var candidates: Set<Double> = [0]
        var candidate = baseLag / 8
        while candidate < settings.maxLeadMs {
            candidates.insert(candidate)
            candidate *= 2
        }
        candidates.insert(settings.maxLeadMs)
        let leads = candidates.sorted()
        var results: [LeadChoice?] = []
        var bestIndex = -1
        for (index, lead) in leads.enumerated() {
            let bestError = bestIndex < 0 ? Double.infinity : results[bestIndex]!.errorRatio
            let result = tryKnobs(lead: lead, speed: speed, stopAbove: max(accepted, bestError))
            results.append(result)
            if let result {
                if result.errorRatio <= accepted {
                    return index == 0 ? result : refineLead(low: leads[index - 1], high: lead, best: result, speed: speed)
                }
                if result.errorRatio < bestError { bestIndex = index }
            }
        }
        if bestIndex < 0 {
            return tryKnobs(lead: 0, speed: speed) ?? results[0]!
        }
        return minimizeLead(
            low: leads[max(0, bestIndex - 1)],
            high: leads[min(leads.count - 1, bestIndex + 1)],
            best: results[bestIndex]!,
            speed: speed
        )
    }

    private func refineLead(low: Double, high: Double, best: LeadChoice, speed: Double) -> LeadChoice {
        var result = best
        var low = low, high = high
        var iteration = 0
        while iteration < 6 && high - low > 0.5 {
            let mid = (low + high) / 2
            if let attempt = tryKnobs(lead: mid, speed: speed), attempt.errorRatio <= settings.acceptedErrorRatio {
                result = attempt
                high = mid
            } else {
                low = mid
            }
            iteration += 1
        }
        return result
    }

    private func minimizeLead(low: Double, high: Double, best: LeadChoice, speed: Double) -> LeadChoice {
        let golden = (5.0.squareRoot() - 1) / 2
        var result = best
        var a = low, b = high
        var iteration = 0
        while iteration < 12 && b - a > 0.25 {
            let c = b - (b - a) * golden
            let d = a + (b - a) * golden
            let left = tryKnobs(lead: c, speed: speed)
            let right = tryKnobs(lead: d, speed: speed)
            let leftError = left?.errorRatio ?? .infinity
            let rightError = right?.errorRatio ?? .infinity
            if let left, leftError < result.errorRatio { result = left }
            if let right, rightError < result.errorRatio { result = right }
            if result.errorRatio <= settings.acceptedErrorRatio { return result }
            if leftError < rightError { b = d } else { a = c }
            iteration += 1
        }
        return result
    }

    private func tryKnobs(lead leadMs: Double, speed: Double, stopAbove: Double = .infinity) -> LeadChoice? {
        guard let plan = leadKnots(leadMs) else { return nil }
        let knots = plan.knots, changesFromMs = plan.changesFromMs
        var lead = context.lead
        for (t, l) in knots { lead.add(t, l) }
        var speedCurve = context.speed
        let bump: SpeedBump? = speed > 1 ? SpeedBump(
            rampInStartMs: max(context.anchorMs, group.startMs - settings.speedBlendInMs),
            fullStartMs: group.startMs,
            fullEndMs: group.endMs,
            rampOutEndMs: group.endMs + settings.speedBlendOutMs,
            speed: speed
        ) : nil
        if let bump { speedCurve.add(bump) }
        let changeStart = min(changesFromMs, bump?.rampInStartMs ?? .infinity, group.startMs)
        var time = max(windowStartMs, floor(changeStart))
        var state = committedState(at: time)
        var error = 0.0
        for point in group.points {
            state = simulation.run(lead: lead, speed: speedCurve, from: time, to: point.timeMs, state: state)
            time = point.timeMs
            let real = path.position(at: point.timeMs)
            let distance = hypot(state.x - real.x, state.y - real.y)
            error = max(error, distance / point.tolerance)
            if error > stopAbove { break }
        }
        return LeadChoice(leadMs: leadMs, speed: speed, errorRatio: error, endState: state, leadKnots: knots, speedBump: bump)
    }

    /// Spring state without this group's adjustments, sampled every millisecond of the window.
    private func committedState(at t: Double) -> CursorState {
        if committedStates == nil {
            var lead = context.lead
            for (time, l) in leadDecayKnots(path: path, anchorMs: context.anchorMs, anchorLeadMs: context.anchorLeadMs, settings: settings) {
                lead.add(time, l)
            }
            var state = simulation.run(lead: lead, speed: context.speed, from: context.anchorMs, to: windowStartMs, state: context.anchorState)
            let count = max(1, Int(group.startMs.rounded(.up) - windowStartMs) + 1)
            var states: [CursorState] = [state]
            states.reserveCapacity(count)
            if count > 1 {
                for i in 1..<count {
                    let from = windowStartMs + Double(i) - 1
                    state = simulation.run(lead: lead, speed: context.speed, from: from, to: from + 1, state: state)
                    states.append(state)
                }
            }
            committedStates = states
        }
        let states = committedStates!
        let index = Int(min(Double(states.count - 1), max(0, t - windowStartMs)))
        return states[index]
    }

    private func leadKnots(_ leadMs: Double) -> (knots: [(Double, Double)], changesFromMs: Double)? {
        var base = LeadCurve()
        let decay = leadDecayKnots(path: path, anchorMs: context.anchorMs, anchorLeadMs: context.anchorLeadMs, settings: settings)
        for (t, l) in decay { base.add(t, l) }
        if leadMs <= 0 {
            return (decay.filter { $0.0 < group.endMs } + [(group.endMs, base.planned(at: group.endMs))], group.startMs)
        }
        guard let raise = findLeadRaise(leadMs: leadMs, planned: { base.planned(at: $0) }) else { return nil }
        let knots = decay.filter { $0.0 < raise.atMs } + [
            (raise.atMs, base.planned(at: raise.atMs)),
            (raise.atMs + leadStepMs, raise.jumpToMs),
            (group.startMs, leadMs),
            (group.endMs, leadMs),
        ]
        return (knots, raise.atMs)
    }

    /// Where the lead can rise to `leadMs` without visibly skipping: inside a rest of the cursor,
    /// or compressed into the last 400 ms before the group.
    private func findLeadRaise(leadMs: Double, planned: (Double) -> Double) -> (atMs: Double, jumpToMs: Double)? {
        let start = group.startMs
        let earliest = max(context.anchorMs, start - settings.approachWindowMs)
        func acceptable(_ at: Double, _ jump: Double) -> Bool {
            let rate = (start + leadMs - (at + jump)) / (start - at)
            return rate >= 1 - settings.leadDecayPerMs && rate <= settings.maxCompressionRate
        }
        var rest = path.lastRest(endingBy: start + leadMs)
        while let current = rest, current.endMs > earliest {
            let at = min(start - 1, max(earliest, current.endMs - leadMs))
            let existing = planned(at)
            let jump = min(leadMs, current.endMs - at)
            if at + min(jump, existing) >= current.startMs && at + max(jump, existing) <= current.endMs && acceptable(at, jump) {
                return (at, jump)
            }
            rest = path.lastRest(endingBy: current.startMs)
        }
        let compressionStart = max(context.anchorMs, start - settings.compressionWindowMs)
        if compressionStart >= start { return nil }
        let existing = planned(compressionStart)
        return acceptable(compressionStart, existing) ? (compressionStart, existing) : nil
    }
}

// MARK: - Planned path

/// The smoothed cursor for a whole timeline, sampled every millisecond.
public final class SmoothedCursorPath: @unchecked Sendable {
    private struct Run {
        var startMs: Double
        var xs: [Float]
        var ys: [Float]
    }

    private let runs: [Run]
    private let initial: Vec2
    private let lead: LeadCurve
    private let maxLeadMs: Double

    private init(runs: [Run], initial: Vec2, lead: LeadCurve, maxLeadMs: Double) {
        self.runs = runs
        self.initial = initial
        self.lead = lead
        self.maxLeadMs = maxLeadMs
    }

    /// - Parameters:
    ///   - points: recorded positions, sorted by time.
    ///   - syncPoints: moments where the drawn cursor must match the recorded one.
    ///   - spring: cursor spring, nil = follow the recording exactly.
    ///   - instantRanges: ranges where the cursor follows the recording exactly.
    public static func plan(
        points: [CursorPathPoint],
        syncPoints: [CursorSyncPoint],
        spring: SpringConfig?,
        durationMs: Double,
        instantRanges: [TimeRange] = [],
        cutTimesMs: [Double] = [],
        settings: CursorPathSettings = CursorPathSettings()
    ) -> SmoothedCursorPath {
        let path = RecordedCursorPath(points: points)
        let instant = spring == nil ? [TimeRange(startMs: -.infinity, endMs: .infinity)] : instantRanges
        let simulation = CursorSimulation(path: path, spring: spring ?? .cursor, instantRanges: instant)
        let sync = syncPoints.filter { !simulation.isInstant($0.timeMs) }
        var groups = groupSyncPoints(sync, gapMs: settings.groupGapMs)
        let origin = min(0, path.startMs)

        struct Committed {
            var group: SyncGroup
            var choice: LeadChoice
            var leadBefore: LeadCurve
            var speedBefore: SpeedCurve
        }
        var committed: [Committed] = []
        var lead = LeadCurve(cutTimesMs: cutTimesMs)
        var speed = SpeedCurve()
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let previous = committed.last
            let planner = SyncGroupPlanner(
                path: path,
                simulation: simulation,
                settings: settings,
                group: group,
                context: PlanContext(
                    anchorMs: previous?.group.endMs ?? origin,
                    anchorLeadMs: previous?.choice.endLeadMs ?? 0,
                    anchorState: previous?.choice.endState ?? .resting(at: path.position(at: origin)),
                    lead: lead,
                    speed: speed
                )
            )
            let choice = planner.choose()
            if choice.errorRatio > 1, let previous, group.startMs - previous.group.endMs <= settings.mergeGapMs {
                // Too close to fix separately: undo the previous group and plan both together.
                committed.removeLast()
                lead = previous.leadBefore
                speed = previous.speedBefore
                groups[index] = SyncGroup(startMs: previous.group.startMs, endMs: group.endMs, points: previous.group.points + group.points)
                continue
            }
            let leadBefore = lead, speedBefore = speed
            choice.commit(to: &lead, speed: &speed)
            committed.append(Committed(group: group, choice: choice, leadBefore: leadBefore, speedBefore: speedBefore))
            index += 1
        }
        let last = committed.last
        for (t, l) in leadDecayKnots(path: path, anchorMs: last?.group.endMs ?? origin, anchorLeadMs: last?.choice.endLeadMs ?? 0, settings: settings) {
            lead.add(t, l)
        }
        return simulate(simulation: simulation, lead: lead, speed: speed, durationMs: durationMs, maxLeadMs: settings.maxLeadMs)
    }

    private static func groupSyncPoints(_ points: [CursorSyncPoint], gapMs: Double) -> [SyncGroup] {
        var groups: [SyncGroup] = []
        for point in points.sorted(by: { $0.timeMs < $1.timeMs }) {
            if let last = groups.last, point.timeMs - last.endMs <= gapMs {
                groups[groups.count - 1].points.append(point)
                groups[groups.count - 1].endMs = point.timeMs
            } else {
                groups.append(SyncGroup(startMs: point.timeMs, endMs: point.timeMs, points: [point]))
            }
        }
        return groups
    }

    private static func simulate(simulation: CursorSimulation, lead: LeadCurve, speed: SpeedCurve, durationMs: Double, maxLeadMs: Double) -> SmoothedCursorPath {
        let start = min(0, floor(simulation.path.startMs))
        let initial = simulation.target(lead: lead, at: start)
        var runs: [Run] = []
        var runStart = 0.0
        var xs: [Float] = []
        var ys: [Float] = []
        var lastX = initial.x, lastY = initial.y
        func flush() {
            if !xs.isEmpty { runs.append(Run(startMs: runStart, xs: xs, ys: ys)) }
            xs = []
            ys = []
        }
        _ = simulation.run(
            lead: lead,
            speed: speed,
            from: start,
            to: max(start, durationMs.rounded(.up)),
            state: .resting(at: initial)
        ) { t, x, y in
            if x == lastX && y == lastY {
                flush()
                return
            }
            if xs.isEmpty { runStart = t }
            xs.append(Float(x))
            ys.append(Float(y))
            lastX = x
            lastY = y
        }
        flush()
        return SmoothedCursorPath(runs: runs, initial: initial, lead: lead, maxLeadMs: maxLeadMs)
    }

    /// When the drawn cursor aims at the recorded position of time `t`: the earliest instant
    /// whose target time (instant plus lead) reaches `t`, found by bisection.
    public func targetTime(of t: Double) -> Double {
        var low = t - maxLeadMs - 1
        var high = t
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if middle + lead.at(middle) >= t { high = middle } else { low = middle }
        }
        return high
    }

    public func position(at t: Double) -> Vec2 {
        guard let i = floorSearch(count: runs.count, value: t, key: { runs[$0].startMs }) else { return initial }
        let run = runs[i]
        let offset = t - run.startMs
        let last = run.xs.count - 1
        if offset >= Double(last) { return Vec2(Double(run.xs[last]), Double(run.ys[last])) }
        let i0 = Int(offset)
        let f = offset - Double(i0)
        return Vec2(
            Double(run.xs[i0]) + Double(run.xs[i0 + 1] - run.xs[i0]) * f,
            Double(run.ys[i0]) + Double(run.ys[i0 + 1] - run.ys[i0]) * f
        )
    }
}
