import Foundation
import Testing
@testable import RegravaCore

@Suite struct LoupeTests {
    private func project(_ zooms: [ZoomRange]) -> Project {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 12_000, fps: 60), mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(960, 540))])
        p.zooms = zooms
        return p
    }

    @Test func loupeKeepsTheScreenStillAndCondensesInPlace() throws {
        let p = project([ZoomRange(startMs: 2000, endMs: 6000, scale: 2, mode: .manual, manualTarget: Vec2(0.3, 0.6), presentation: .loupe)])
        let track = CameraTrack(project: p)
        let rest = track.layout.restScreen
        let during = track.frame(at: 4000)
        #expect(abs(during.screenRect.width - rest.width) < 0.5 && abs(during.screenRect.x - rest.x) < 0.5)
        let lens = try #require(during.loupe)
        #expect(abs(lens.zoom - 2) < 0.01 && abs(lens.presence - 1) < 0.01)
        #expect(abs(lens.radius - 0.35) < 0.001)
        #expect(abs(lens.center.x - 0.3) < 0.02 && abs(lens.center.y - 0.6) < 0.02)
        // Long after, the lens sits at the same place with no optics: invisible.
        #expect(track.frame(at: 11_000).loupe == nil)
        // Before the loupe, the nearest zoom is that loupe: same radius, zoom 1.
        let planner = CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, sparse: p.mouseEvents)
        let before = planner.loupeTarget(at: 500)
        #expect(!before.isActive && before.frame.radius > 0.3 && before.frame.zoom == 1 && before.frame.presence == 0)
    }

    @Test func aClassicNeighbourCollapsesTheLens() {
        let p = project([
            ZoomRange(startMs: 1000, endMs: 3000, scale: 2, presentation: .loupe),
            ZoomRange(startMs: 3500, endMs: 6000, scale: 2),
        ])
        let planner = CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, sparse: p.mouseEvents)
        #expect(planner.loupeTarget(at: 3400).frame == .none)
        #expect(planner.loupeTarget(at: 3100).frame.radius > 0)
    }

    @Test func loupeSpringIsStifferThanTheScreen() {
        let p = project([ZoomRange(startMs: 1000, endMs: 3000, presentation: .loupe)])
        let planner = CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, sparse: p.mouseEvents)
        #expect(planner.loupeSpring(at: 2000).stiffness == p.animation.screenSpring.stiffness * 1.5)
    }

    @Test func oldZoomsDecodeAsClassicWithDefaultOptions() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startMs":0,"endMs":1000}"#
        let zoom = try JSONDecoder().decode(ZoomRange.self, from: Data(json.utf8))
        #expect(zoom.presentation == .screen && zoom.loupeOptions == LoupeOptions())
    }

    @Test func cameraCoverageIsTheLensShareOfTheCamera() {
        let p = project([])
        let planner = CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, sparse: p.mouseEvents)
        let screen = Rect2(x: 0, y: 0, width: 1000, height: 1000)
        let camera = Rect2(x: 400, y: 400, width: 200, height: 200)
        func lens(_ radius: Double, at center: Vec2 = Vec2(0.5, 0.5), active: Bool = true) -> (frame: LoupeFrame, isActive: Bool) {
            (LoupeFrame(center: center, radius: radius, zoom: 2, bevelRatio: 0, chromaticAberration: 0, shadowAlpha: 0, presence: 1), active)
        }
        // A disc inside the camera: π·r² over 40 000.
        #expect(planner.isCameraCoveredByLoupe(camera: camera, screen: screen, target: lens(0.085)))  // ≈ 0.57
        #expect(!planner.isCameraCoveredByLoupe(camera: camera, screen: screen, target: lens(0.075))) // ≈ 0.44
        #expect(planner.isCameraCoveredByLoupe(camera: camera, screen: screen, target: lens(0.5)))
        #expect(!planner.isCameraCoveredByLoupe(camera: camera, screen: screen, target: lens(0.5, active: false)))
        #expect(!planner.isCameraCoveredByLoupe(camera: camera, screen: screen, target: lens(0)))
        // Far from the camera.
        #expect(!planner.isCameraCoveredByLoupe(camera: camera, screen: screen, target: lens(0.2, at: Vec2(0.05, 0.05))))
    }
}
