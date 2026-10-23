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
