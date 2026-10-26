import Darwin
import Foundation

// Background decode lanes: a budget of hardware decode sessions that analyses (a sensitive data
// scan, camera sweeps, cursor hover analysis...) may hold at once. Inside one process the lanes are
// tracked in memory. When `REGRAVA_DECODE_DIR` names a directory, the budget is shared by every
// process using that directory: lane N is held through an exclusive `flock` on `lane-N.lock`, the
// budget comes from `budget.json`, waiting callers leave a `waiting-<ms>-<pid>-<number>` file so
// callers are served in arrival order across processes, and interactive decoding (scrubbers) is
// published in `interactive.json`. Every interactive stream decoding right now takes two lanes away
// from the background budget, which never drops below one lane.

extension SD {
    final class DecodeLanes: @unchecked Sendable {
        /// Environment variable naming the directory shared by every process that splits the budget.
        static let directoryEnvironmentKey = "REGRAVA_DECODE_DIR"

        static let shared = DecodeLanes(
            directory: ProcessInfo.processInfo.environment[directoryEnvironmentKey]
                .map { URL(fileURLWithPath: $0) }
        )

        /// How a host process sets the background budget (`budget.json`).
        struct Budget: Decodable {
            let backgroundLaneCount: Int
        }

        /// One caller waiting for a lane. Callers are served by `(whole start ms, pid, number)`.
        struct Waiter: Hashable {
            let startedAtMs: Double
            let number: Int
            let processId: Int32

            var fileName: String {
                "waiting-" + String(Int(startedAtMs)) + "-" + String(processId) + "-" + String(number)
            }
        }

        let directory: URL?
        let lock = NSLock()
        var budgetReadAt: Date = .distantPast
        var backgroundLaneCount = 8
        var interactiveStreamCount = 0
        var heldIndexes: Set<Int> = []
        var waitersInProcess: Set<Waiter> = []
        var waiterCount = 0

        init(directory: URL?) {
            self.directory = directory
        }

        /// Lanes background work may hold now: the budget minus two per interactive stream, at least one.
        var allowedLaneCount: Int {
            lock.lock()
            rereadBudgetIfStale()
            let count = max(backgroundLaneCount - interactiveStreamCount * 2, 1)
            lock.unlock()
            return count
        }

        /// Refreshes the budget at most every 0.25 s. Caller holds `lock`.
        func rereadBudgetIfStale() {
            let now = Date()
            guard now.timeIntervalSince(budgetReadAt) >= 0.25 else { return }
            budgetReadAt = now
            guard let directory else {
                let activity = InteractiveDecodeActivity.shared
                activity.lock.lock()
                let count = activity.countActive(at: Date())
                activity.lock.unlock()
                interactiveStreamCount = count
                return
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("budget.json")),
               let budget = try? JSONDecoder().decode(Budget.self, from: data) {
                backgroundLaneCount = max(budget.backgroundLaneCount, 1)
            }
            interactiveStreamCount = 0
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("interactive.json")),
                  let report = try? JSONDecoder().decode(InteractiveDecodeActivity.Report.self, from: data)
            else { return }
            // A report older than 5 s comes from a host that is gone or stuck.
            if now.timeIntervalSince1970 * 1000 - report.writtenAtMs < 5000 {
                interactiveStreamCount = report.activeStreamCount
            }
        }

        /// Blocks until a lane is free and every earlier waiter was served, polling every 50 ms.
        /// Returns nil once `isCancelled` says so.
        func acquire(isCancelled: () -> Bool) -> DecodeLane? {
            let startedAt = Date().timeIntervalSince1970
            lock.lock()
            waiterCount += 1
            let number = waiterCount
            lock.unlock()
            let me = Waiter(startedAtMs: startedAt * 1000, number: number, processId: getpid())
            if isCancelled() { return nil }
            if !hasWaiter(before: me), let lane = tryAcquire() { return lane }
            startWaiting(me)
            var lane: DecodeLane?
            while true {
                Thread.sleep(forTimeInterval: 0.05)
                if isCancelled() { break }
                if !hasWaiter(before: me), let taken = tryAcquire() {
                    lane = taken
                    break
                }
            }
            stopWaiting(me)
            return lane
        }

        /// Takes one lane (waiting like `acquire(isCancelled:)`), then as many more free lanes as are
        /// available right away, up to `upTo`, without jumping ahead of any waiter.
        func acquire(upTo: Int, isCancelled: () -> Bool) -> [DecodeLane] {
            guard let first = acquire(isCancelled: isCancelled) else { return [] }
            var lanes = [first]
            let me = Waiter(startedAtMs: Date().timeIntervalSince1970 * 1000, number: .max, processId: getpid())
            while lanes.count < upTo {
                if hasWaiter(before: me) { break }
                guard let lane = tryAcquire() else { break }
                lanes.append(lane)
            }
            return lanes
        }

        /// Whether another live waiter (in this process, or in any process sharing the directory)
        /// arrived before `me`.
        func hasWaiter(before me: Waiter) -> Bool {
            guard let directory else {
                lock.lock()
                defer { lock.unlock() }
                for other in waitersInProcess where other != me {
                    if Self.isOrdered(other, before: me) { return true }
                }
                return false
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                let parts = name.split(separator: "-")
                guard parts.count == 4, parts[0] == "waiting",
                      let startedAtMs = Double(parts[1]),
                      let processId = Int32(parts[2]),
                      let number = Int(parts[3])
                else { continue }
                let other = Waiter(startedAtMs: startedAtMs, number: number, processId: processId)
                guard other != me, Self.isOrdered(other, before: me) else { continue }
                // A file left by a process that died does not hold anyone up.
                if processId == getpid() || kill(processId, 0) == 0 || errno == EPERM { return true }
            }
            return false
        }

        static func isOrdered(_ a: Waiter, before b: Waiter) -> Bool {
            let aMs = Int(a.startedAtMs), bMs = Int(b.startedAtMs)
            if aMs != bMs { return aMs < bMs }
            if a.processId != b.processId { return a.processId < b.processId }
            return a.number < b.number
        }

        /// The lowest free lane below the allowed count, or nil.
        func tryAcquire() -> DecodeLane? {
            let limit = allowedLaneCount
            lock.lock()
            defer { lock.unlock() }
            for index in 0..<limit where !heldIndexes.contains(index) {
                var descriptor: Int32 = -1
                if let directory {
                    let path = directory.appendingPathComponent("lane-" + String(index) + ".lock").path
                    descriptor = open(path, O_RDWR | O_CREAT, 0o644)
                    guard descriptor >= 0 else { continue }
                    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                        close(descriptor)
                        continue
                    }
                }
                heldIndexes.insert(index)
                return DecodeLane(index: index, descriptor: descriptor, lanes: self)
            }
            return nil
        }

        func startWaiting(_ waiter: Waiter) {
            lock.lock()
            waitersInProcess.insert(waiter)
            lock.unlock()
            guard let directory else { return }
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(waiter.fileName).path, contents: nil, attributes: nil)
        }

        func stopWaiting(_ waiter: Waiter) {
            lock.lock()
            waitersInProcess.remove(waiter)
            lock.unlock()
            guard let directory else { return }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(waiter.fileName))
        }
    }

    /// One held lane. Released by `release()` or when the last reference goes away.
    final class DecodeLane: @unchecked Sendable {
        let index: Int
        let descriptor: Int32
        let lanes: DecodeLanes
        let lock = NSLock()
        var isReleased = false

        init(index: Int, descriptor: Int32, lanes: DecodeLanes) {
            self.index = index
            self.descriptor = descriptor
            self.lanes = lanes
        }

        deinit {
            release()
        }

        /// Whether the budget shrank below this lane, so its holder should give it back soon.
        var isOverBudget: Bool {
            lanes.allowedLaneCount <= index
        }

        func release() {
            lock.lock()
            let wasReleased = isReleased
            isReleased = true
            lock.unlock()
            guard !wasReleased else { return }
            lanes.lock.lock()
            lanes.heldIndexes.remove(index)
            lanes.lock.unlock()
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
    }

    /// Interactive decoding (scrubbers serving a waiting renderer) of this process. A stream counts
    /// as active for 1 s after its last decode and is forgotten after 30 s. With a shared directory
    /// the count is published in `interactive.json` (checked every 0.25 s, written when it changes or
    /// every 2 s while non-zero) so background processes shrink their budget.
    final class InteractiveDecodeActivity: @unchecked Sendable {
        static let shared = InteractiveDecodeActivity(directory: DecodeLanes.shared.directory)

        struct Report: Codable {
            let activeStreamCount: Int
            let writtenAtMs: Double
        }

        let directory: URL?
        let lock = NSLock()
        var lastDecodeByStream: [ObjectIdentifier: Date] = [:]
        var writtenCount = 0
        var writtenAt: Date = .distantPast
        var isWatching = false

        init(directory: URL?) {
            self.directory = directory
        }

        var activeStreamCount: Int {
            lock.lock()
            let count = countActive(at: Date())
            lock.unlock()
            return count
        }

        /// Caller holds `lock`.
        func countActive(at now: Date) -> Int {
            lastDecodeByStream = lastDecodeByStream.filter { now.timeIntervalSince($0.value) < 30 }
            var active: [Date] = []
            for date in lastDecodeByStream.values where now.timeIntervalSince(date) < 1.0 {
                active.append(date)
            }
            return active.count
        }

        func noteDecoding(_ stream: AnyObject) {
            lock.lock()
            lastDecodeByStream[ObjectIdentifier(stream)] = Date()
            guard !isWatching, directory != nil else {
                lock.unlock()
                return
            }
            isWatching = true
            lock.unlock()
            startWatching()
        }

        func forget(_ stream: AnyObject) {
            lock.lock()
            lastDecodeByStream[ObjectIdentifier(stream)] = nil
            lock.unlock()
        }

        func startWatching() {
            let thread = Thread { [weak self] in
                while let self {
                    if let directory = self.directory {
                        let now = Date()
                        self.lock.lock()
                        let count = self.countActive(at: now)
                        if count != self.writtenCount
                            || (count > 0 && now.timeIntervalSince(self.writtenAt) >= 2.0) {
                            self.writtenCount = count
                            self.writtenAt = now
                            self.lock.unlock()
                            let report = Report(activeStreamCount: count, writtenAtMs: now.timeIntervalSince1970 * 1000)
                            if let data = try? JSONEncoder().encode(report) {
                                try? data.write(to: directory.appendingPathComponent("interactive.json"), options: .atomic)
                            }
                        } else {
                            self.lock.unlock()
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            thread.name = "interactive-decode-activity"
            thread.qualityOfService = .utility
            thread.start()
        }
    }
}
