import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

@Suite(.enabled(if: SDTestData.hasClip)) struct EdgesTests {
    let dummy: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        return ctx.makeImage()!
    }()

    func refiner() -> SD.EdgeRefiner {
        let scanner = try! SDTestData.scanner()
        return SD.EdgeRefiner(scanner: scanner, timeline: SD.ChangeTimeline(samples: []), sampledTimesMs: [], memo: [:])
    }

    func item(_ kind: String, _ key: String) -> SD.TrackedItem {
        SD.TrackedItem(id: 1, kind: kind, text: key, key: key, startMs: 0, endMs: 0, lastSeenMs: 0, lastSeenRect: .zero,
                       keyframes: [], endIfGoneMs: 0)
    }

    func image(_ w: Int, _ h: Int, _ f: (Int) -> Int) -> SD.GrayImage {
        SD.GrayImage(bytes: Data((0..<(w * h)).map { UInt8(clamping: f($0)) }), widthPx: w, heightPx: h, originPx: .zero, cgImage: dummy)
    }

    @Test func memoKeyHashesKindKeySideRectPresenceAndCandidates() {
        let a = item("email", "abc0"), b = item("custom:Natan", "natan")
        typealias Edge = SD.EdgeRefiner.Edge
        let edges = [
            Edge(item: a, isStart: true, cropRect: CGRect(x: 100, y: 200, width: 300, height: 40), presentMs: 1250,
                 candidates: [(previousMs: 1150, changeMs: 1200)]),
            Edge(item: b, isStart: false, cropRect: CGRect(x: 10.7, y: 0, width: 88.2, height: 31.9), presentMs: 4000,
                 candidates: [(previousMs: 4000, changeMs: 4050), (previousMs: 4100, changeMs: 4150)]),
            Edge(item: b, isStart: true, cropRect: CGRect(x: 0, y: 0, width: 8, height: 8), presentMs: 0, candidates: []),
        ]
        #expect(edges.map(SD.EdgeRefiner.memoKey) == [16082681998890888968, 11384019419274492638, 11220712247637310756])
    }

    @Test func sameLookComparesMeanDifferencePerEightPixelBlock() {
        let r = refiner()
        let base = image(20, 13) { ($0 * 37) % 251 }
        #expect(r.isSameLook(base, image(20, 13) { ($0 * 37) % 251 + 3 }, toleranceLevels: 3))
        #expect(!r.isSameLook(base, image(20, 13) { ($0 * 37) % 251 + 4 }, toleranceLevels: 3))
        // Differences are summed with their sign inside a block, so alternating noise cancels only per block.
        #expect(!r.isSameLook(base, image(20, 13) { ($0 * 37) % 251 + ($0 % 2 == 0 ? 20 : -20) }, toleranceLevels: 0))
        // A single bright pixel in a clipped corner block (4×5 px) exceeds 8 levels on average.
        #expect(!r.isSameLook(base, image(20, 13) { $0 == 259 ? 255 : ($0 * 37) % 251 }, toleranceLevels: 8))
        #expect(!r.isSameLook(base, image(20, 13) { $0 == 259 ? 0 : ($0 * 37) % 251 }, toleranceLevels: 0))
        #expect(!r.isSameLook(base, image(13, 20) { ($0 * 37) % 251 }, toleranceLevels: 8))
        #expect(r.isSameLook(base, base, toleranceLevels: 0))
    }
}
