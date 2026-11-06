import CoreGraphics
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct MatteFlickerTests {
    let n = 4
    func flat(_ v: UInt8) -> [UInt8] { [UInt8](repeating: v, count: n) }
    func guide(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { flat(r) + flat(g) + flat(b) }

    @Test func threeFramesTakeTheirMedianWhereTheFootageIsStill() {
        let g = guide(100, 100, 100)
        let out = MatteFlicker.filter(mattes: (nil, flat(10), flat(200), flat(20), nil), guides: (g, g, g))
        #expect(out == flat(20))
    }

    @Test func fiveFramesUseTheFiveTapMedian() {
        let g = guide(100, 100, 100)
        // lo = max(min(200, 20), min(10, 50)) = 20, hi = min(max(200, 20), max(10, 50)) = 50,
        // e = 30: max(min(max(20, 30), 50), min(20, 30)) = 30.
        let out = MatteFlicker.filter(mattes: (flat(50), flat(10), flat(200), flat(20), flat(30)), guides: (g, g, g))
        #expect(out == flat(30))
    }

    @Test func movingFootageKeepsTheOwnMatte() {
        let own = guide(100, 100, 100)
        // 11² × 3 = 363 < 417: still. 12² × 3 = 432: moved.
        let still = MatteFlicker.filter(mattes: (nil, flat(10), flat(200), flat(20), nil), guides: (guide(111, 111, 111), own, own))
        #expect(still == flat(20))
        let moved = MatteFlicker.filter(mattes: (nil, flat(10), flat(200), flat(20), nil), guides: (own, own, guide(112, 112, 112)))
        #expect(moved == flat(200))
    }

    @Test func withoutBothNeighboursTheMatteStays() {
        let g = guide(0, 0, 0)
        #expect(MatteFlicker.filter(mattes: (nil, nil, flat(200), flat(20), flat(30)), guides: (nil, g, g)) == flat(200))
        #expect(MatteFlicker.filter(mattes: (nil, flat(10), flat(200), flat(20), nil), guides: (g, g, nil)) == flat(200))
    }

    @Test func aChunkFiltersWithItsContextFrames() {
        let g = guide(50, 50, 50)
        let values: [UInt8] = [10, 200, 20, 220, 30, 40]
        let flicker = ChunkFlicker(start: 1, end: 4, frameCount: 6)
        for (frame, v) in values.enumerated() { flicker.add(frame, matte: flat(v), guide: g) }
        let mattes = flicker.finish()
        // Frame 1: 3 taps (no frame −1) → median(10, 200, 20) = 20. Frame 2: 5 taps of
        // (10, 200, 20, 220, 30) → 30. Frame 3: 5 taps of (200, 20, 220, 30, 40) → 40.
        #expect(mattes == [flat(20), flat(30), flat(40)])
    }
}

struct MatteChunkTests {
    @Test func lumaTablesMatchTheVideoRange() {
        #expect([0, 1, 128, 254, 255].map { MatteChunkWriter.videoRangeLuma[$0] } == [16, 16, 125, 234, 235])
        #expect([0, 15, 16, 17, 125, 234, 235, 240, 255].map { MatteChunkReader.fullRange[$0] } == [0, 0, 0, 1, 126, 253, 255, 255, 255])
    }

    @Test func chunksRoundTripThroughTheCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matte-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = MatteCache.matteWidth, h = MatteCache.matteHeight
        let cache = try MatteCache(root: root, videoKey: "/v.mov|1|2", identity: "matte-x", frameCount: 45)
        #expect(cache.chunkCount == 2)
        #expect(cache.frames(ofChunk: 1) == 30..<45)
        // A soft person: a horizontal ramp that moves a little each frame.
        let mattes: [[UInt8]] = (0..<15).map { f in
            var m = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { m[y * w + x] = UInt8(min(max((x - 300 - f * 4) / 2, 0), 255)) } }
            return m
        }
        try cache.write(1, mattes: mattes)
        #expect(cache.isStored(1))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("matte-x/chunk-000001.mp4").path))
        let read = try cache.read(1)
        #expect(read.count == 15)
        var worst = 0
        for (a, b) in zip(mattes, read) {
            for i in stride(from: 0, to: w * h, by: 7) {
                let expected = Int(MatteChunkReader.fullRange[Int(MatteChunkWriter.videoRangeLuma[Int(a[i])])])
                worst = max(worst, abs(expected - Int(b[i])))
            }
        }
        #expect(worst <= 3)
        // Reopened for the same video, the chunk is still there; for another frame count, not.
        #expect(try MatteCache(root: root, videoKey: "/v.mov|1|2", identity: "matte-x", frameCount: 45).isStored(1))
        #expect(!(try MatteCache(root: root, videoKey: "/v.mov|1|2", identity: "matte-x", frameCount: 46).isStored(1)))
    }
}

struct MatteCacheTests {
    func cache(frames: Int) throws -> (MatteCache, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matte-test-" + UUID().uuidString, isDirectory: true)
        return (try MatteCache(root: root, videoKey: "/v.mov|1|2", identity: "matte-a", frameCount: frames), root)
    }

    @Test func claimsNearestTheDemandFirstAndThoseBeforeAtTwiceTheDistance() throws {
        let (c, root) = try cache(frames: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        // Priorities: 4→0, 5→1, 3→2, 6→2 (ties keep chunk order), 7→3, 2→4, 8→4, 9→5, 1→6, 0→8.
        #expect(c.claimMissing(near: 4, count: 5) == [4, 5, 3, 6, 7])
        #expect(c.claimMissing(near: 4, count: 3) == [2, 8, 9])
        c.release([5])
        #expect(c.claimMissing(near: 2, count: 2) == [1, 5])
    }

    @Test func identityHashesTheVideoModelAndWindow() {
        #expect(MatteCache.identity(videoKey: "/tmp/x.mov|10|20", model: "vision-person-segmentation-accurate", window: CGRect(x: 0, y: 0, width: 1, height: 1)) == "matte-6a23e08830359d9bc4fe")
        #expect(MatteCache.root(forVideoAt: "/a/b/P.regrava/camera.mov").path == "/a/b/P.regrava/cache/camera-matte")
    }

    @Test func otherIdentitiesOfTheSameVideoAreDeleted() throws {
        let (c, root) = try cache(frames: 30)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try MatteCache(root: root, videoKey: "/v.mov|9|9", identity: "matte-old", frameCount: 30)
        _ = try MatteCache(root: root, videoKey: "/w.mov|1|2", identity: "matte-other", frameCount: 30)
        c.deleteOtherIdentities()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(names == ["matte-a", "matte-other"])
    }
}
