import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

/// Compares the tracking helpers with reference results recorded for random inputs
/// (/tmp/C-work/units.json: rects, strings, synthetic 10 x 6 tile timelines, keyframes).
@Suite("Tracking helpers on recorded random cases", .enabled(if: SDTestData.hasReference))
struct TrackingUnitTests {
    static let path = SDTestData.path("C-work/units.json")
    static let grid = SD.TileGrid(widthPx: 320, heightPx: 192, tilesX: 10, tilesY: 6)

    func rect(_ v: Any) -> CGRect { TrackingFixtures.rect(v) }
    /// Equal once both went through JSON (numbers then compare as the same decimal text).
    func same(_ a: Any, _ b: Any) -> Bool {
        func normalized(_ v: Any) -> NSArray {
            let data = try! JSONSerialization.data(withJSONObject: [v])
            return try! JSONSerialization.jsonObject(with: data) as! NSArray
        }
        return normalized(a) == normalized(b)
    }
    func rectOut(_ r: CGRect) -> Any { r.isNull ? NSNull() : [r.origin.x, r.origin.y, r.size.width, r.size.height] }

    @Test("every recorded case matches")
    func recordedCases() throws {
        let cases = try TrackingFixtures.json(Self.path) as! [[String: Any]]
        var failures: [String: Int] = [:]
        var examples: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok {
                failures[name, default: 0] += 1
                if failures[name]! <= 2 { examples.append("\(name): \(detail())") }
            }
        }
        for c in cases {
            let iou = c["iou"] as! [Any]
            check("iou", same(Double(SD.intersectionOverUnion(rect(iou[0]), rect(iou[1]))), iou[2]), "\(iou) mine \(SD.intersectionOverUnion(rect(iou[0]), rect(iou[1])))")

            let edit = c["edit"] as! [Any]
            check("edit", SD.editDistance(Array(edit[0] as! String), Array(edit[1] as! String), limit: edit[2] as! Int) == edit[3] as! Int)

            let cov = c["covered"] as! [Any]
            let o = SD.Observation(timeMs: 0, region: rect(cov[1]), faceRegion: rect(cov[2]), lines: [], findings: [], firstTile: 0, tileSignatures: [])
            check("covered", SD.isCovered(rect(cov[0]), by: o, kind: cov[3] as! String) == ((cov[4] as! Int) == 1))

            let samples = (c["samples"] as! [Any]).map(TrackingFixtures.sample)
            let timeline = SD.ChangeTimeline(samples: samples)
            let tracker = SD.Tracker(observations: [], timeline: timeline, grid: Self.grid, options: SD.Options(), durationMs: 5000)

            let sig = c["tlsig"] as! [Any]
            let mine: Any = timeline.signature(ofTile: sig[0] as! Int, atMs: sig[1] as! Int).map { $0.map { Int($0) } } ?? NSNull()
            check("signature", same(mine, sig[2]))

            let ch = c["changes"] as! [Any]
            let tiles = ch[0] as! [Int]
            let mineChanges: Any = timeline.changes(inAnyOf: tiles, afterMs: ch[1] as! Int, upToMs: ch[2] as! Int).map { [$0.firstMs, $0.lastMs] } ?? NSNull()
            check("changes", same(mineChanges, ch[3]))
            let sud = c["sudden"] as! [Any]
            check("sudden", timeline.hasSuddenChange(in: tiles, afterMs: sud[1] as! Int, upToMs: sud[2] as! Int) == ((sud[3] as! Int) == 1))

            if let moved = c["moved"] as? [Any] {
                let r = tracker.moved(rect(moved[0]), fromMs: moved[1] as! Int, toMs: moved[2] as! Int)
                check("moved", same(r.map(rectOut) ?? NSNull(), moved[3]))
                let walk = c["walk"] as! [Any]
                var w = SD.Tracker.MotionWalk(tracker: tracker, stripe: walk[1] as! Int)
                var wr = rect(walk[0])
                var steps: [Any] = []
                for s in samples {
                    let dy = w.step(wr, in: s)
                    steps.append([dy.map { Double($0) } ?? NSNull(), Double(w.heldPx), w.heldSinceMs, w.heldTiles.sorted(), w.lastShiftMoved])
                    if let dy { wr = wr.offsetBy(dx: 0, dy: -dy) }
                }
                check("walk", same(steps, walk[2]))
            }

            let item = c["item"] as! [Any]
            let kfs = (item[0] as! [[Double]]).map { (timeMs: Int($0[0]), rect: CGRect(x: $0[1], y: $0[2], width: $0[3], height: $0[4])) }
            let tracked = SD.TrackedItem(id: 0, kind: "secret", text: "t", key: "k", startMs: 0, endMs: 0, lastSeenMs: 0,
                                         lastSeenRect: .null, keyframes: kfs, endIfGoneMs: 0)
            let vel: [Any] = (-1 ... 5).map { i -> Any in
                if let v = tracked.velocity(at: i) { return [Double(v.dx), Double(v.dy)] }
                return NSNull()
            }
            check("velocity", same(vel, item[1]), "\(item[0]) \(vel) vs \(item[1])")
            check("isStill", tracked.isStill == ((item[2] as! Int) == 1))

            let off = c["offscreen"] as! [Any]
            let ms = tracker.offScreenMs(from: (timeMs: off[0] as! Int, rect: rect(off[1])),
                                         velocity: CGVector(dx: off[2] as! Double, dy: off[3] as! Double), isForward: off[4] as! Bool)
            check("offScreen", same(ms ?? NSNull(), off[5]))
        }
        #expect(cases.count > 0)
        #expect(failures.isEmpty, "\(failures) of \(cases.count): \(examples)")
    }
}

@Suite("Detection dictionaries on recorded random items", .serialized, .enabled(if: SDTestData.hasReference))
struct DetectionObjectsTests {
    @Test("rounding, held keyframes, exact edges and text masking match")
    func recordedItems() throws {
        let runs = try TrackingFixtures.json(SDTestData.path("C-work/detections.json")) as! [[String: Any]]
        let saved = SD.options
        defer { SD.options = saved }
        for run in runs {
            SD.options.isTextRedacted = run["redacted"] as! Bool
            let items = (run["items"] as! [[String: Any]]).map { d -> SD.TrackedItem in
                let item = SD.TrackedItem(id: d["id"] as! Int, kind: d["kind"] as! String, text: d["text"] as! String, key: d["key"] as! String,
                                          startMs: d["startMs"] as! Int, endMs: d["endMs"] as! Int, lastSeenMs: 0, lastSeenRect: .null,
                                          keyframes: (d["keyframes"] as! [[Double]]).map { (timeMs: Int($0[0]), rect: CGRect(x: $0[1], y: $0[2], width: $0[3], height: $0[4])) },
                                          endIfGoneMs: 0, isTyped: d["isTyped"] as! Bool)
                item.exactStartMs = (d["exactStartMs"] as? NSNumber)?.doubleValue
                item.exactEndMs = (d["exactEndMs"] as? NSNumber)?.doubleValue
                if let held = d["heldKeyframes"] as? [[Double]] {
                    item.heldKeyframes = held.map { (timeMs: $0[0], rect: CGRect(x: $0[1], y: $0[2], width: $0[3], height: $0[4])) }
                }
                return item
            }
            let mine = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: SD.detectionObjects(items))) as! NSArray
            let reference = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: run["detections"]!)) as! NSArray
            #expect(mine == reference)
        }
    }
}
