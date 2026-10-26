import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

/// Normalizes a detection dictionary to plain JSON values, so two outputs compare with ==.
private func normalized(_ value: Any) -> Any {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    return try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func describe(_ detection: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: detection, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

@Suite("Resolving stored evidence", .enabled(if: SDTestData.hasReference))
struct TrackingResolveTests {
    @Test("clip15 evidence resolves to the reference detections")
    func clip15Detections() throws {
        let chunks = try TrackingFixtures.storedChunks()
        let memo = try TrackingFixtures.edgeMemo()
        let scanner = try SDTestData.scanner()
        let resolver = SD.SensitiveDataResolver(scanner: scanner, cache: try SDTestData.cache(for: scanner),
                                                layers: SD.ChunkLayers(faceLayer: nil, phrases: []),
                                                remembersDecisions: true, edgeMemo: memo)
        let resolved = resolver.resolve(chunks, endMs: TrackingFixtures.durationMs, isFinal: true)
        let mine = SD.detectionObjects(resolved.items)
        let reference = (try TrackingFixtures.json(TrackingFixtures.expectedOutput) as! [String: Any])["detections"] as! [[String: Any]]

        let out = mine.map(describe).joined(separator: "\n")
        try out.write(toFile: NSTemporaryDirectory() + "mine.jsonl", atomically: true, encoding: .utf8)
        try reference.map(describe).joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "ref.jsonl", atomically: true, encoding: .utf8)

        #expect(mine.count == reference.count)
        var mismatches = 0
        for (a, b) in zip(mine, reference) {
            let na = normalized(a) as! NSDictionary
            let nb = normalized(b) as! NSDictionary
            if na != nb { mismatches += 1 }
        }
        #expect(mismatches == 0)
        #expect(resolved.refinedEdges == 80)
    }
}

@Suite("Tracking stored evidence", .enabled(if: SDTestData.hasReference))
struct TrackingTrackTests {
    @Test("tracking the clip15 reads gives the reference items")
    func clip15Items() throws {
        let (observations, samples) = try TrackingFixtures.joined()
        let tracker = SD.Tracker(observations: observations, timeline: SD.ChangeTimeline(samples: samples),
                                 grid: TrackingFixtures.grid, options: SD.Options(), durationMs: TrackingFixtures.durationMs)
        let items = tracker.track()
        try TrackingFixtures.writeJSON(items.map(TrackingFixtures.itemJSON), NSTemporaryDirectory() + "mine-track.json")
        let reference = try TrackingFixtures.json(SDTestData.path("C-work/orig-track.json")) as! [[String: Any]]
        let mine = try TrackingFixtures.json(NSTemporaryDirectory() + "mine-track.json") as! [[String: Any]]
        #expect((mine as NSArray) == (reference as NSArray))
    }
}

@Suite("Tracking pieces on stored evidence", .enabled(if: SDTestData.hasReference))
struct TrackingPiecesTests {
    func tracker() throws -> SD.Tracker {
        let (observations, samples) = try TrackingFixtures.joined()
        return SD.Tracker(observations: observations, timeline: SD.ChangeTimeline(samples: samples),
                          grid: TrackingFixtures.grid, options: SD.Options(), durationMs: TrackingFixtures.durationMs)
    }

    @Test("start estimates of every finding")
    func startEstimates() throws {
        let t = try tracker()
        var res: [[Int]] = []
        for (i, o) in t.observations.enumerated() {
            for (j, f) in o.findings.enumerated() {
                let e = t.startMs(of: f, foundAt: i)
                res.append([i, j, e.startMs, e.evidence?.absentMs ?? 0, e.evidence?.presentMs ?? 0, e.evidence == nil ? 1 : 0, e.isTyped ? 1 : 0])
            }
        }
        let reference = try TrackingFixtures.json(SDTestData.path("C-work/orig-startall.json")) as! [[Int]]
        try TrackingFixtures.writeJSON(res, NSTemporaryDirectory() + "mine-startall.json")
        #expect(res == reference)
    }

    @Test("typed prefixes of every finding in the 8 reads before it")
    func typedPrefixes() throws {
        let t = try tracker()
        var res: [[Int]] = []
        for (i, o) in t.observations.enumerated() {
            for (fi, f) in o.findings.enumerated() {
                for j in max(0, i - 8) ..< i {
                    for (li, line) in t.observations[j].lines.enumerated() {
                        let single = SD.Observation(timeMs: 0, region: .null, faceRegion: .null, lines: [line], findings: [],
                                                    firstTile: 0, tileSignatures: [])
                        if t.hasTypedPrefix(of: f, in: single) { res.append([i, fi, j, li]) }
                    }
                }
            }
        }
        let reference = try TrackingFixtures.json(SDTestData.path("C-work/orig-typed.json")) as! [[Int]]
        try TrackingFixtures.writeJSON(res, NSTemporaryDirectory() + "mine-typed.json")
        #expect(res == reference)
    }
}
