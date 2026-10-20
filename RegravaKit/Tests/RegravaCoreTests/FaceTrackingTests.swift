import Foundation
import Testing
@testable import RegravaCore

struct FaceTrackingTests {
    let faces = CameraFaces(intervalMs: 100, samples: [
        CameraFaceSample(timeMs: 0, confidence: 0, rect: nil),
        CameraFaceSample(timeMs: 100, confidence: 0.9, rect: Rect2(x: 0.6, y: 0.2, width: 0.2, height: 0.2)),
        CameraFaceSample(timeMs: 200, confidence: 0.3, rect: Rect2(x: 0.0, y: 0.0, width: 0.2, height: 0.2)),
        CameraFaceSample(timeMs: 300, confidence: 0.8, rect: Rect2(x: 0.2, y: 0.4, width: 0.2, height: 0.2)),
    ], analyzedUntilMs: 300, isComplete: true)

    @Test func holdsTheLastConfidentFace() {
        let confident = FaceTracking.confident(faces)
        #expect(FaceTracking.faceCenter01(confident: confident, cameraTimeMs: 50, crop01: nil) == FaceTracking.noFaceCenter)
        func near(_ a: Vec2, _ b: Vec2) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
        #expect(near(FaceTracking.faceCenter01(confident: confident, cameraTimeMs: 100, crop01: nil), Vec2(0.7, 0.3)))
        // The 0.3 sample is ignored: the 100 ms face is held.
        #expect(near(FaceTracking.faceCenter01(confident: confident, cameraTimeMs: 250, crop01: nil), Vec2(0.7, 0.3)))
        #expect(near(FaceTracking.faceCenter01(confident: confident, cameraTimeMs: 5000, crop01: nil), Vec2(0.3, 0.5)))
        #expect(FaceTracking.faceCenter01(confident: nil, cameraTimeMs: 100, crop01: nil) == FaceTracking.noFaceCenter)
    }

    @Test func remapsIntoTheCropAndClamps() {
        let crop = Rect2(x: 0.5, y: 0, width: 0.5, height: 1)
        #expect(FaceTracking.pointIntoCrop(Vec2(0.75, 0.5), crop) == Vec2(0.5, 0.5))
        #expect(FaceTracking.pointIntoCrop(Vec2(0.2, 0.5), crop) == Vec2(0, 0.5))
    }

    @Test func focalAxisCentresTheFaceWithinTheImage() {
        // 200-wide image over a 100-wide frame at 0: a face at 0.75 centres at 150 → origin −100.
        #expect(FaceTracking.focalAxis(imageOrigin: -50, imageLength: 200, frameOrigin: 0, frameLength: 100, focal01: 0.75) == -100)
        #expect(FaceTracking.focalAxis(imageOrigin: -50, imageLength: 200, frameOrigin: 0, frameLength: 100, focal01: 0.1) == 0)
        #expect(FaceTracking.focalAxis(imageOrigin: 0, imageLength: 100, frameOrigin: 0, frameLength: 100, focal01: 0.9) == 0)
    }

    @Test func trackSpringsTheFocalPointTowardTheFace() {
        var project = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 2, durationMs: 4000, fps: 60, cameraFileName: "camera.mov", cameraSize: Size2(width: 1280, height: 720)), mouseEvents: [])
        let faces = CameraFaces(intervalMs: 100, samples: [CameraFaceSample(timeMs: 0, confidence: 0.9, rect: Rect2(x: 0.7, y: 0.2, width: 0.2, height: 0.2))], analyzedUntilMs: 4000, isComplete: true)
        #expect(CameraTrack(project: project, faces: faces).frame(at: 3000).cameraFocal01 == Vec2(0.5, 0.5))
        project.camera.enableFaceTracking = true
        let focal = CameraTrack(project: project, faces: faces).frame(at: 3000).cameraFocal01
        #expect(abs(focal.x - 0.8) < 0.01 && abs(focal.y - 0.3) < 0.01)
        project.camera.mirror = true
        #expect(abs(CameraTrack(project: project, faces: faces).frame(at: 3000).cameraFocal01.x - 0.2) < 0.01)
    }
}
