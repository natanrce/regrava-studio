import Foundation
import Testing
@testable import RegravaCore

struct CursorHoverTests {
    @Test func hoversCountOnlyWithTheToggleAndSmoothMovement() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 100, height: 100), pointPixelScale: 1, durationMs: 1000, fps: 60), mouseEvents: [])
        let hovers = CursorHovers(chunks: [.init(startMs: 0, endMs: 1000, result: [400, 200])])
        #expect(project.cursorHoverTimes(hovers) == [200, 400])
        project.cursor.followRecordedPositionOnHover = false
        #expect(project.cursorHoverTimes(hovers).isEmpty)
        project.cursor.followRecordedPositionOnHover = true
        project.animation.mouseSpring = nil
        #expect(project.cursorHoverTimes(hovers).isEmpty)
        #expect(hovers.covers(durationMs: 1000) && !CursorHovers(chunks: [.init(startMs: 0, endMs: 500, result: [])]).covers(durationMs: 1000))
    }

    @Test func hoverSyncPointsUseFourPoints() {
        let points = CameraTrack.cursorSyncPoints(events: [], pointPixelScale: 2, hoverTimesMs: [100])
        #expect(points.count == 1 && points[0].reason == .hover && points[0].tolerance == 8)
    }
}

struct CursorHoverStretchTests {
    @Test func sessionsAreReadInTwentySecondStretchesTheLastOpenEnded() {
        let open = CursorHovers.openEndMs
        #expect(CursorHovers.stretches(durationMs: 9758.17).map(\.endMs) == [open])
        #expect(CursorHovers.stretches(durationMs: 41_000).map { [$0.startMs, $0.endMs] } == [[0, 20_000], [20_000, 40_000], [40_000, open]])
        #expect(CursorHovers.stretches(durationMs: 45_000).map(\.startMs) == [0, 20_000, 40_000])
        let long = CursorHovers.stretches(durationMs: 600_000)
        #expect(long.count == 30 && long.last == .init(startMs: 580_000, endMs: open) && long[28].endMs == 580_000)
        #expect(open == 9_007_199_254_740_991)
    }

    /// A 10 min session with the playhead at 5:00, its first two stretches already started.
    @Test func stretchesNearestThePlayheadGoFirstThoseBehindCountingDouble() {
        let pending = Array(CursorHovers.stretches(durationMs: 600_000).dropFirst(2))
        let order = CursorHovers.scheduled(pending, demandMs: 300_000).map { Int($0.startMs / 1000) }
        #expect(order == [280, 300, 320, 260, 340, 360, 240, 380, 400, 220, 420, 440, 200, 460, 480, 180,
                          500, 520, 160, 540, 560, 140, 580, 120, 100, 80, 60, 40])
        #expect(CursorHovers.scheduled(pending, demandMs: nil) == pending)
        #expect(CursorHovers.scheduled(CursorHovers.stretches(durationMs: 600_000), demandMs: 0).prefix(2).map(\.startMs) == [0, 20_000])
    }

    @Test func finishedStretchesAreReadableBeforeTheWholeResult() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("regrava-hover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let grid = CursorHovers.stretches(durationMs: 45_000)
        #expect(CursorHovers.load(bundle: bundle) == nil)
        try CursorHovers.saveStretch([41_200.5], bundle: bundle, grid[2])
        try CursorHovers.saveStretch([], bundle: bundle, grid[0])
        let stored = try String(contentsOf: CursorHovers.stretchURL(bundle: bundle, grid[2]), encoding: .utf8)
        #expect(stored == #"{"json":[41200.5]}"#)
        #expect(CursorHovers.stretchURL(bundle: bundle, grid[2]).lastPathComponent == "0-40000-9007199254740991.json")
        let partial = try #require(CursorHovers.load(bundle: bundle))
        #expect(partial.chunks.map(\.stretch) == [grid[0], grid[2]] && partial.timesMs == [41_200.5])
        #expect(!partial.covers(durationMs: 45_000))
        #expect(CursorHovers.loadStretch(bundle: bundle, grid[1]) == nil)
        // The whole result, once written, is what loads.
        try CursorHovers(chunks: grid.map { .init(startMs: $0.startMs, endMs: $0.endMs, result: []) }).save(bundle: bundle)
        #expect(CursorHovers.load(bundle: bundle)?.covers(durationMs: 45_000) == true)
    }
}
