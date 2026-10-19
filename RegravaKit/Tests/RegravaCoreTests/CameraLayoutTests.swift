import Foundation
import Testing
@testable import RegravaCore

struct CameraLayoutTests {
    let info = StageInfo(aspectRatio: nil, sourceSize: Size2(width: 1920, height: 1080), paddingRatio01: 0.1, avoidEmptyZoomArea: false, cameraSourceAspectRatio: 16.0 / 9)

    func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) < tolerance }

    @Test func padByRatioGrowsAndShrinksByShortestSide() {
        let r = Rect2(x: 0, y: 0, width: 1920, height: 1080)
        let grown = r.padByRatio(0.1)
        #expect(near(grown.width, 2136) && near(grown.height, 1296) && near(grown.x, -108))
        let shrunk = r.padByRatio(-0.1)
        #expect(near(shrunk.height, 900) && near(shrunk.x, 90))
    }

    @Test func screenOnlyUsesAutoStageAndFittedScreen() {
        let r = LayoutResolver.screenOnly(info)
        #expect(near(r.aspectRatio, 2136.0 / 1296))
        #expect(near(r.zoomArea.x, 90) && near(r.zoomArea.y, 90) && near(r.zoomArea.height, 900))
        #expect(near(r.initialScreenRect.width, 1600) && near(r.initialScreenRect.height, 900))
        #expect(r.cameraRect == nil)
    }

    @Test func overlayCameraSitsInBottomRightCorner() {
        let r = LayoutResolver.overlay(OverlayLayoutOptions(), info)
        let camera = r.cameraRect!
        #expect(near(camera.width, 540) && near(camera.height, 540))
        #expect(near(camera.endX, r.stageRect.endX - 60) && near(camera.endY, 1020))
        let zoomed = r.zoomedCameraRect!
        #expect(near(zoomed.width, 432))
    }

    @Test func splitAutoAspectFallsBackToClampedFormula() {
        #expect(near(LayoutResolver.splitAutoAspect(paddingRatio: 0, screenAspect: 16.0 / 9), (16.0 / 9 * 1000 + 562.5) / 1000))
        #expect(LayoutResolver.splitAutoAspect(paddingRatio: 0, screenAspect: 1) == 16.0 / 9)
    }

    @Test func splitPutsScreenLeftAndCameraRight() {
        var i = info
        i.aspectRatio = 16.0 / 9
        let r = LayoutResolver.split(SplitLayoutOptions(), i)
        let camera = r.cameraRect!
        #expect(near(camera.endX, r.stageRect.endX))
        #expect(r.zoomArea.x < camera.x)
        #expect(r.zoomedVariant.kind == .overlay)
    }

    @Test func anchorAvoidsCamera() {
        let zone = Rect2(x: 0, y: 0, width: 1000, height: 1000)
        let camera = Rect2(x: 600, y: 0, width: 400, height: 1000)
        let a = LayoutMath.anchor(zoomArea: zone, camera: camera)
        #expect(near(a.x, 300) && near(a.y, 500))
        #expect(LayoutMath.anchor(zoomArea: zone, camera: nil) == Vec2(500, 500))
    }

    @Test func fullscreenRangeKeepsNeighbouringScreenLayout() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 2, durationMs: 10000, fps: 60, cameraFileName: "camera.mov", cameraSize: Size2(width: 1280, height: 720)), mouseEvents: [])
        project.cameraLayouts = [
            CameraLayoutRange(startMs: 1000, endMs: 3000, type: .splitScreen),
            CameraLayoutRange(startMs: 3000.5, endMs: 5000, type: .fullscreenCamera),
        ]
        let timeline = LayoutTimeline(project: project)
        #expect(timeline.screenResolver(at: 3500).kind == .split)
        #expect(timeline.screenResolver(at: 4500).kind == .overlay)
        #expect(timeline.cameraResolver(at: 4500).kind == .fullscreenCamera)
        #expect(timeline.cameraResolver(at: 6000).kind == .overlay)
    }

    @Test func trackPlacesAndHidesTheCamera() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 2, durationMs: 10000, fps: 60, cameraFileName: "camera.mov", cameraSize: Size2(width: 1280, height: 720)), mouseEvents: [])
        project.style.aspectRatio = 16.0 / 9
        project.cameraLayouts = [CameraLayoutRange(startMs: 4000, endMs: 8000, type: .screenOnly)]
        let track = CameraTrack(project: project)
        let visible = track.frame(at: 2000)
        #expect(visible.cameraOpacity > 0.99)
        let camera = visible.cameraRect!
        #expect(abs(camera.maxX - (1920 - 60)) < 1 && abs(camera.maxY - (1080 - 60)) < 1)
        #expect(abs(visible.cameraCornerRadius - 540 * 0.15) < 0.5)
        #expect(track.frame(at: 7000).cameraOpacity < 0.01)
        #expect(track.frame(at: 7000).cameraRect!.width < camera.width)

        project.camera.hide = true
        #expect(CameraTrack(project: project).frame(at: 2000).cameraRect == nil)
    }
}
