import Foundation
import Testing
@testable import RegravaCore

@Suite struct SliceTests {
    private func project(_ duration: Double = 10_000) -> Project {
        Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: duration, fps: 60), mouseEvents: [])
    }

    @Test func newProjectsHaveOneClip() {
        let p = project()
        #expect(p.slices.count == 1)
        #expect(p.playbackDurationMs == 10_000)
    }

    @Test func resolverMapsSpeedAndCuts() {
        var p = project()
        p.splitSlice(at: 4000)
        p.splitSlice(at: 6000)
        p.slices[1].timeScale = 1.0 / 2           // 4–6 s at 2×
        p.updateSlice(p.slices[2].id, sourceStartMs: 7000) // cut 6–7 s
        let r = p.resolver
        #expect(r.playbackDurationMs == 4000 + 1000 + 3000)
        #expect(r.sourceToPlayback(5000) == 4500)
        #expect(r.playbackToSource(4500) == 5000)
        #expect(r.playbackToSource(5000) == 6000 || r.playbackToSource(5000) == 7000)
        #expect(r.playbackToSource(5500) == 7500)
        #expect(!r.isSourceTimePresent(6500))
        #expect(r.speed(atPlayback: 4200) == 2)
    }

    @Test func splitNeedsRoomOnBothSides() {
        var p = project()
        #expect(!p.canSplitSlice(at: 50))
        let r1 = p.splitSlice(at: 3000)
        #expect(r1)
        #expect(p.slices.map(\.sourceEndMs) == [3000, 10_000])
        #expect(p.slices[1].id != p.slices[0].id)
    }

    @Test func trimsAreClampedAndJoinsRestore() {
        var p = project()
        p.splitSlice(at: 5000)
        let second = p.slices[1].id
        let r2 = p.updateSlice(second, sourceStartMs: 4000)
        #expect(r2)   // cannot overlap the previous clip
        #expect(p.slices[1].sourceStartMs == 5000)
        let r3 = p.updateSlice(second, sourceStartMs: 6000)
        #expect(r3)
        #expect(p.sliceHasStartTrim(1))
        let r4 = p.updateSlice(second, sourceStartMs: 9950)
        #expect(!r4)  // would be shorter than 100 ms
        p.removeSliceTrim(second, edge: .start)
        #expect(p.slices[1].sourceStartMs == 5000)
        p.mergeSlice(second, with: .previous)
        #expect(p.slices.count == 1 && p.slices[0].sourceStartMs == 0 && p.slices[0].sourceEndMs == 10_000)
    }

    @Test func lastClipCannotBeRemoved() {
        var p = project()
        let r5 = p.removeSlice(p.slices[0].id)
        #expect(!r5)
        p.splitSlice(at: 5000)
        let r6 = p.removeSlice(p.slices[1].id)
        #expect(r6)
        #expect(p.playbackDurationMs == 5000)
    }

    @Test func oldProjectsGetOneClip() throws {
        var p = project()
        p.splitSlice(at: 2000)
        let data = try JSONEncoder().encode(p)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "slices")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.slices.count == 1)
    }
}
