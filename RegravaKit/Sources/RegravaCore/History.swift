import Foundation

/// A trailing debounce with a maximum wait, on an explicit clock (milliseconds).
///
/// `call(at:)` registers a call and returns true when the function must run right away
/// (the maximum wait has passed since the last run). Otherwise the owner arms a timer for
/// `deadline` and calls `timerFired(at:)`, which returns true when the function must run.
public struct Debouncer: Equatable, Sendable {
    public let waitMs: Double
    public let maxWaitMs: Double
    private var lastCallTime: Double?
    private var lastInvokeTime: Double = 0
    private var hasPendingCall = false
    /// When the armed timer fires; nil when no timer is armed.
    public private(set) var deadline: Double?

    public init(waitMs: Double, maxWaitMs: Double) {
        self.waitMs = waitMs
        self.maxWaitMs = max(maxWaitMs, waitMs)
    }

    private func shouldInvoke(_ time: Double) -> Bool {
        guard let lastCallTime else { return true }
        let sinceLastCall = time - lastCallTime
        return sinceLastCall >= waitMs || sinceLastCall < 0 || time - lastInvokeTime >= maxWaitMs
    }

    public mutating func call(at time: Double) -> Bool {
        let isInvoking = shouldInvoke(time)
        lastCallTime = time
        hasPendingCall = true
        if isInvoking {
            if deadline == nil {
                // Leading edge: starts the wait without running.
                lastInvokeTime = time
                deadline = time + waitMs
                return false
            }
            deadline = time + waitMs
            invoke(at: time)
            return true
        }
        if deadline == nil { deadline = time + waitMs }
        return false
    }

    public mutating func timerFired(at time: Double) -> Bool {
        guard deadline != nil else { return false }
        if shouldInvoke(time) {
            deadline = nil
            guard hasPendingCall else { return false }
            invoke(at: time)
            return true
        }
        let sinceLastCall = time - (lastCallTime ?? time)
        let sinceLastInvoke = time - lastInvokeTime
        deadline = time + min(waitMs - sinceLastCall, maxWaitMs - sinceLastInvoke)
        return false
    }

    private mutating func invoke(at time: Double) {
        lastInvokeTime = time
        hasPendingCall = false
    }
}

/// Undo history of whole states. Changes go into a buffer that becomes one step once no
/// change has come for 100 ms (or 5 s after the buffer started); undo and redo flush it
/// first. Keeps the last 1000 steps.
public struct UndoHistory<State> {
    public static var maxSteps: Int { 1000 }
    public static var bufferWaitMs: Double { 100 }
    public static var bufferMaxWaitMs: Double { 5000 }

    /// States before each step, oldest first.
    public private(set) var undoStates: [State] = []
    /// States after each undone step, the next one to redo last.
    public private(set) var redoStates: [State] = []
    /// The state before the first buffered change.
    public private(set) var bufferedState: State?
    public private(set) var debouncer = Debouncer(waitMs: UndoHistory.bufferWaitMs, maxWaitMs: UndoHistory.bufferMaxWaitMs)

    public init() {}

    /// Steps in the history (buffered changes aren't a step yet).
    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    /// Registers a change from `previous`. True when the buffer became a step right away.
    @discardableResult
    public mutating func record(changingFrom previous: State, at time: Double) -> Bool {
        if bufferedState == nil { bufferedState = previous }
        guard debouncer.call(at: time) else { return false }
        flush()
        return true
    }

    /// The buffer timer fired. True when the buffer became a step.
    @discardableResult
    public mutating func timerFired(at time: Double) -> Bool {
        guard debouncer.timerFired(at: time) else { return false }
        return flush()
    }

    /// Turns the buffered changes into one step, dropping the steps that were undone.
    @discardableResult
    public mutating func flush() -> Bool {
        guard let state = bufferedState else { return false }
        bufferedState = nil
        redoStates.removeAll()
        undoStates.append(state)
        if undoStates.count > Self.maxSteps { undoStates.removeFirst(undoStates.count - Self.maxSteps) }
        return true
    }

    /// The state to restore, given the current one; nil when there is nothing to undo.
    public mutating func undo(current: State) -> State? {
        flush()
        guard let previous = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return previous
    }

    /// The state to restore, given the current one; nil when there is nothing to redo.
    public mutating func redo(current: State) -> State? {
        flush()
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return next
    }
}
