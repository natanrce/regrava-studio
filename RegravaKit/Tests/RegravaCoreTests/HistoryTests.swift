import Testing
@testable import RegravaCore

@Suite struct HistoryTests {
    /// Drives the history like the editor: a change records the old state, the timer fires
    /// at its deadline.
    private struct Driver {
        var history = UndoHistory<Int>()
        var state = 0
        var now = 0.0

        mutating func advance(to time: Double) {
            while let deadline = history.debouncer.deadline, deadline <= time {
                now = deadline
                history.timerFired(at: deadline)
            }
            now = time
        }

        mutating func change(to value: Int, at time: Double) {
            advance(to: time)
            history.record(changingFrom: state, at: time)
            state = value
        }

        mutating func undo() { if let s = history.undo(current: state) { state = s } }
        mutating func redo() { if let s = history.redo(current: state) { state = s } }
    }

    @Test func changesLessThan100msApartAreOneStep() {
        var d = Driver()
        d.change(to: 1, at: 0)
        d.change(to: 2, at: 99)
        d.change(to: 3, at: 198)
        #expect(!d.history.canUndo)          // still buffered
        d.advance(to: 298)
        #expect(d.history.undoStates == [0])
        d.change(to: 4, at: 1000)
        d.advance(to: 2000)
        #expect(d.history.undoStates == [0, 3])
    }

    @Test func pauseOf100msStartsANewStep() {
        var d = Driver()
        d.change(to: 1, at: 0)
        d.change(to: 2, at: 100)
        d.advance(to: 1000)
        #expect(d.history.undoStates == [0, 1])
    }

    @Test func continuousChangesSplitEvery5Seconds() {
        var d = Driver()
        var t = 0.0
        var value = 0
        while t <= 6000 {
            value += 1
            d.change(to: value, at: t)
            t += 50
        }
        d.advance(to: 10_000)
        // The 5 s maximum wait closes the first step before the change at 5000 ms.
        #expect(d.history.undoStates == [0, 100])
    }

    @Test func undoFlushesTheBufferFirst() {
        var d = Driver()
        d.change(to: 1, at: 0)
        d.advance(to: 500)
        d.change(to: 2, at: 1000)
        d.change(to: 3, at: 1050)
        d.undo()
        #expect(d.state == 1)
        d.undo()
        #expect(d.state == 0)
        #expect(!d.history.canUndo)
        d.redo()
        d.redo()
        #expect(d.state == 3)
        // The timer still armed by the flushed buffer does nothing.
        d.advance(to: 5000)
        #expect(d.history.undoStates == [0, 1])
    }

    @Test func newStepDropsRedoOnlyWhenFlushed() {
        var d = Driver()
        d.change(to: 1, at: 0)
        d.advance(to: 500)
        d.undo()
        #expect(d.history.canRedo)
        d.change(to: 5, at: 1000)
        #expect(d.history.canRedo)
        d.advance(to: 1100)
        #expect(!d.history.canRedo)
        #expect(d.history.undoStates == [0])
    }

    @Test func keeps1000Steps() {
        var d = Driver()
        for i in 1...1005 { d.change(to: i, at: Double(i) * 1000) }
        d.advance(to: 2_000_000)
        #expect(d.history.undoStates.count == 1000)
        #expect(d.history.undoStates.first == 5)
    }

    @Test func debouncerMatchesTrailingWithMaxWait() {
        var debouncer = Debouncer(waitMs: 100, maxWaitMs: 5000)
        let r1 = debouncer.call(at: 0)
        #expect(r1 == false)
        #expect(debouncer.deadline == 100)
        let r2 = debouncer.call(at: 60)
        #expect(r2 == false)
        let r3 = debouncer.timerFired(at: 100)
        #expect(r3 == false)
        #expect(debouncer.deadline == 160)
        let r4 = debouncer.timerFired(at: 160)
        #expect(r4 == true)
        #expect(debouncer.deadline == nil)
    }
}
