import Darwin
import Foundation
import Testing
@testable import RegravaRender

@Suite(.serialized) struct DecodeLanesTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-lanes-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lockState(_ url: URL) -> String {
        let fd = open(url.path, O_RDWR)
        if fd < 0 { return "nofile" }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return "free"
        }
        return "held"
    }

    @Test func withoutDirectoryEightLanesInMemory() {
        let lanes = SD.DecodeLanes(directory: nil)
        #expect(lanes.allowedLaneCount == 8)
        let held = lanes.acquire(upTo: 20, isCancelled: { false })
        #expect(held.map(\.index) == Array(0..<8))
        #expect(held.allSatisfy { $0.descriptor == -1 })
        #expect(lanes.tryAcquire() == nil)
        held[3].release()
        held[3].release()
        #expect(lanes.tryAcquire()?.index == 3)
    }

    @Test func releasedOnDeinit() {
        let lanes = SD.DecodeLanes(directory: nil)
        do {
            let lane = lanes.tryAcquire()
            #expect(lane?.index == 0)
        }
        #expect(lanes.heldIndexes.isEmpty)
    }

    @Test func cancelledWhileWaitingPollsAndReturnsNil() {
        let lanes = SD.DecodeLanes(directory: nil)
        let held = lanes.acquire(upTo: 8, isCancelled: { false })
        #expect(held.count == 8)
        var calls = 0
        let start = Date()
        let lane = lanes.acquire(isCancelled: { calls += 1; return calls > 3 })
        #expect(lane == nil)
        #expect(calls == 4)
        #expect(Date().timeIntervalSince(start) >= 0.15)
        #expect(lanes.waitersInProcess.isEmpty)
    }

    @Test func cancelledBeforeTheFirstTry() {
        let lanes = SD.DecodeLanes(directory: nil)
        #expect(lanes.acquire(isCancelled: { true }) == nil)
        #expect(lanes.heldIndexes.isEmpty)
    }

    @Test func waiterOrder() {
        typealias W = SD.DecodeLanes.Waiter
        // Whole milliseconds first, then process id, then arrival number.
        #expect(SD.DecodeLanes.isOrdered(W(startedAtMs: 10.9, number: 9, processId: 9), before: W(startedAtMs: 11.0, number: 1, processId: 1)))
        #expect(!SD.DecodeLanes.isOrdered(W(startedAtMs: 10.1, number: 1, processId: 2), before: W(startedAtMs: 10.9, number: 2, processId: 1)))
        #expect(SD.DecodeLanes.isOrdered(W(startedAtMs: 10.1, number: 1, processId: 1), before: W(startedAtMs: 10.9, number: 2, processId: 1)))
        #expect(W(startedAtMs: 1730000000123.7, number: 4, processId: 77).fileName == "waiting-1730000000123-77-4")
    }

    @Test func earlierInProcessWaiterBlocksExtraLanes() {
        let lanes = SD.DecodeLanes(directory: nil)
        let earlier = SD.DecodeLanes.Waiter(startedAtMs: 1, number: 1, processId: getpid())
        lanes.startWaiting(earlier)
        var calls = 0
        #expect(lanes.acquire(upTo: 3, isCancelled: { calls += 1; return calls > 1 }).isEmpty)
        lanes.stopWaiting(earlier)
        #expect(lanes.acquire(upTo: 3, isCancelled: { false }).map(\.index) == [0, 1, 2])
    }

    @Test func budgetFileAndLockFiles() throws {
        let dir = makeDirectory()
        try Data(#"{"backgroundLaneCount":3}"#.utf8).write(to: dir.appendingPathComponent("budget.json"))
        let lanes = SD.DecodeLanes(directory: dir)
        #expect(lanes.allowedLaneCount == 3)
        let held = lanes.acquire(upTo: 10, isCancelled: { false })
        #expect(held.map(\.index) == [0, 1, 2])
        #expect(held.allSatisfy { $0.descriptor >= 0 })
        for i in 0..<3 { #expect(lockState(dir.appendingPathComponent("lane-\(i).lock")) == "held") }
        #expect(lockState(dir.appendingPathComponent("lane-3.lock")) == "nofile")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("lane-0.lock").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o644)
        held[1].release()
        #expect(lockState(dir.appendingPathComponent("lane-1.lock")) == "free")
        #expect(lanes.tryAcquire()?.index == 1)
    }

    @Test func lockHeldByAnotherDescriptorIsSkipped() {
        let dir = makeDirectory()
        let fd = open(dir.appendingPathComponent("lane-0.lock").path, O_RDWR | O_CREAT, 0o644)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let lanes = SD.DecodeLanes(directory: dir)
        #expect(lanes.tryAcquire()?.index == 1)
        close(fd)
    }

    @Test func budgetClampsAndFallsBack() throws {
        let dir = makeDirectory()
        try Data(#"{"backgroundLaneCount":0}"#.utf8).write(to: dir.appendingPathComponent("budget.json"))
        #expect(SD.DecodeLanes(directory: dir).allowedLaneCount == 1)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("budget.json"))
        #expect(SD.DecodeLanes(directory: dir).allowedLaneCount == 8)
    }

    @Test func interactiveReportShrinksBudgetWhileFresh() throws {
        let dir = makeDirectory()
        try Data(#"{"backgroundLaneCount":6}"#.utf8).write(to: dir.appendingPathComponent("budget.json"))
        func write(_ count: Int, ageMs: Double) throws {
            let ms = Date().timeIntervalSince1970 * 1000 - ageMs
            try Data(#"{"activeStreamCount":\#(count),"writtenAtMs":\#(ms)}"#.utf8)
                .write(to: dir.appendingPathComponent("interactive.json"))
        }
        let lanes = SD.DecodeLanes(directory: dir)
        try write(2, ageMs: 0)
        #expect(lanes.allowedLaneCount == 2)
        try write(1, ageMs: 0)
        // Read at most every 0.25 s.
        #expect(lanes.allowedLaneCount == 2)
        usleep(300_000)
        #expect(lanes.allowedLaneCount == 4)
        usleep(300_000)
        try write(2, ageMs: 6000)
        #expect(lanes.allowedLaneCount == 6)
        let held = lanes.acquire(upTo: 3, isCancelled: { false })
        usleep(300_000)
        try write(2, ageMs: 0)
        #expect(held.map(\.isOverBudget) == [false, false, true])
    }

    @Test func waitingFilesOrderProcesses() {
        let dir = makeDirectory()
        let live = getppid()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("waiting-1-\(live)-1").path, contents: nil)
        let lanes = SD.DecodeLanes(directory: dir)
        var calls = 0
        var seen: [String] = []
        let lane = lanes.acquire(isCancelled: {
            calls += 1
            if calls == 2 { seen = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }
            return calls > 3
        })
        #expect(lane == nil)
        #expect(seen.contains { $0.hasPrefix("waiting-") && $0.contains("-\(getpid())-") })
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.contains("-\(getpid())-") })
        // A file left by a process that is gone does not block.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("waiting-1-\(live)-1"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("waiting-1-99999-1").path, contents: nil)
        #expect(lanes.acquire(isCancelled: { false })?.index == 0)
    }

    @Test func countActiveForgetsAfterThirtySeconds() {
        let activity = SD.InteractiveDecodeActivity(directory: nil)
        let a = NSObject(), b = NSObject(), c = NSObject()
        let now = Date()
        activity.lastDecodeByStream = [
            ObjectIdentifier(a): now.addingTimeInterval(-0.5),
            ObjectIdentifier(b): now.addingTimeInterval(-5),
            ObjectIdentifier(c): now.addingTimeInterval(-31),
        ]
        #expect(activity.countActive(at: now) == 1)
        #expect(activity.lastDecodeByStream.count == 2)
        activity.forget(a)
        #expect(activity.countActive(at: now) == 0)
    }

    @Test func reportJSONKeys() throws {
        let data = try JSONEncoder().encode(SD.InteractiveDecodeActivity.Report(activeStreamCount: 2, writtenAtMs: 5))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["activeStreamCount", "writtenAtMs"])
    }
}
