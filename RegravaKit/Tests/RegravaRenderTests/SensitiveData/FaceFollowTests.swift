import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

private func texturedFrame(timeMs: Double, width: Int, height: Int, shiftX: Int = 0, shiftY: Int = 0) -> SD.HalfFrame {
    var pixels = [UInt8](repeating: 128, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let u = x - shiftX, v = y - shiftY
            let value = 128 + 60 * sin(Double(u) / 7) + 50 * cos(Double(v * v) / 2000 + Double(v) / 11 + Double(u) / 13)
            pixels[y * width + x] = UInt8(max(0, min(255, value.rounded())))
        }
    }
    return SD.HalfFrame(timeMs: timeMs, pixels: pixels)
}

@Suite struct FaceFollowTests {
    @Test func steadiestPathStaysFlatInsideAConstantBand() {
        let path = SD.steadiestPath(timesMs: [0, 100, 200, 300], lows: [10, 10, 10, 10], highs: [20, 20, 20, 20])
        #expect(path.first?.value == 15)
        #expect(path.allSatisfy { $0.value == 15 })
        #expect(path.last?.timeMs == 300)
    }

    @Test func valueInterpolatesAndClamps() {
        let path: [(timeMs: Double, value: CGFloat)] = [(0, 0), (100, 10)]
        #expect(SD.value(of: path, atMs: -5) == 0)
        #expect(SD.value(of: path, atMs: 50) == 5)
        #expect(SD.value(of: path, atMs: 500) == 10)
    }

    @Test func scrollStepsMarkUnknownShifts() {
        let samples = [
            SD.ChangeSample(timeMs: 50, isEverything: false, changedTiles: [], changedTileList: [], signatures: nil, stripeShiftsPx: [8, Int16.min]),
            SD.ChangeSample(timeMs: 100, isEverything: true, changedTiles: [], changedTileList: [], signatures: nil, stripeShiftsPx: []),
            SD.ChangeSample(timeMs: 150, isEverything: false, changedTiles: [], changedTileList: [], signatures: nil, stripeShiftsPx: []),
        ]
        let steps = SD.scrollSteps(ofStripe: 1, in: SD.ChangeTimeline(samples: samples))
        #expect(steps.count == 2)
        #expect(steps[0].dy == nil && steps[1].dy == nil)
        #expect(SD.scrollSteps(ofStripe: 0, in: SD.ChangeTimeline(samples: samples))[0].dy == -1)
    }

    @Test func followedFaceFindsAMovedFace() throws {
        let w = 320, h = 240
        let first = texturedFrame(timeMs: 0, width: w, height: h)
        let face = try #require(SD.FollowedFace(rect: CGRect(x: 200, y: 160, width: 96, height: 96), in: first, halfWidth: w, halfHeight: h))
        #expect(face.templateWidth >= 4 && face.templateHeight >= 4)
        let moved = texturedFrame(timeMs: 16, width: w, height: h, shiftX: 3, shiftY: 2)
        let found = face.follow(to: moved, scrollDy: nil)
        #expect(found)
        #expect(abs(face.rect.minX - 206) < 1.5, "x \(face.rect.minX)"); #expect(abs(face.rect.minY - 164) < 1.5, "y \(face.rect.minY)")
        #expect(face.path.count == 2)
    }

    @Test func trackNotLostIsNotCarried() {
        let track = SD.FaceTrack(startMs: 0, endMs: 100, path: [(0, .zero), (100, CGPoint(x: 1, y: 1))],
                                 boxes: [(0, CGRect(x: 0, y: 0, width: 10, height: 10))], isLostAtStart: false, isLostAtEnd: false)
        let carried = SD.carriedAlongScroll(track, scrollSteps: [(150, 4)], frameRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(carried.path.count == 2 && carried.endMs == 100)
        let cover = SD.steadyFaceCover(carried, scrollSteps: [])
        #expect(!cover.isEmpty)
    }
}
