import CoreGraphics
import Foundation
@testable import RegravaRender

/// Loads the JSON form of stored chunk evidence (see /tmp/rgscan/evidence-json/README.md).
enum TrackingFixtures {
    static let evidenceDirectory = SDTestData.path("rgscan/evidence-json/c8/evidence-d4d6b001cc798cec7e4f")
    static let expectedOutput = SDTestData.path("rgscan/orig_noface.json")

    static func json(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func rect(_ value: Any?) -> CGRect {
        guard let array = value as? [Double] else { return .null }
        return CGRect(x: array[0], y: array[1], width: array[2], height: array[3])
    }

    static func finding(_ value: Any) -> SD.Finding {
        let d = value as! [String: Any]
        return SD.Finding(kind: d["kind"] as! String, text: d["text"] as! String, key: d["key"] as! String, rect: rect(d["rect"]))
    }

    static func sample(_ value: Any) -> SD.ChangeSample {
        let d = value as! [String: Any]
        return SD.ChangeSample(
            timeMs: d["timeMs"] as! Int,
            isEverything: d["isEverything"] as! Bool,
            changedTiles: (d["changedTiles"] as! [String]).map { UInt64($0)! },
            changedTileList: d["changedTileList"] as! [Int],
            signatures: bytes(d["signatures"]),
            stripeShiftsPx: (d["stripeShiftsPx"] as! [Int]).map { Int16($0) })
    }

    static func observation(_ value: Any) -> SD.Observation {
        let d = value as! [String: Any]
        return SD.Observation(
            timeMs: d["timeMs"] as! Int,
            region: rect(d["region"]),
            faceRegion: rect(d["faceRegion"]),
            lines: (d["lines"] as! [[String: Any]]).map {
                SD.RecognizedLine(text: $0["text"] as! String, key: $0["key"] as! String, rect: rect($0["rect"]))
            },
            findings: (d["findings"] as! [Any]).map(finding),
            firstTile: d["firstTile"] as! Int,
            tileSignatures: bytes(d["tileSignatures"])!)
    }

    static func bytes(_ value: Any?) -> [UInt8]? {
        if let text = value as? String { return [UInt8](Data(base64Encoded: text)!) }
        if let array = value as? [Int] { return array.map { UInt8($0) } }
        return nil
    }

    static func evidence(_ path: String) throws -> SD.ChunkEvidence {
        let d = try json(path) as! [String: Any]
        return SD.ChunkEvidence(
            chunkIndex: d["chunkIndex"] as! Int,
            changeSamples: (d["changeSamples"] as! [Any]).map(sample),
            sampledTimesMs: d["sampledTimesMs"] as! [Int],
            reads: (d["reads"] as! [Any]).map(observation),
            readHasPhotos: d["readHasPhotos"] as! [Bool])
    }

    static func storedChunks(_ directory: String = evidenceDirectory, facesLayer: String? = nil) throws -> [SD.StoredChunk] {
        try (0 ..< 4).map { index in
            let path = String(format: "%@/chunk-%06d.evidence.json", directory, index)
            var faces: SD.ChunkFaces?
            if let facesLayer {
                let d = try json(String(format: "%@/%@/chunk-%06d.layer.json", directory, facesLayer, index)) as! [String: Any]
                faces = SD.ChunkFaces(facesByRead: (d["facesByRead"] as! [[Any]]).map { $0.map(finding) })
            }
            return SD.StoredChunk(evidence: try evidence(path), faces: faces, phrases: [:])
        }
    }

    static func edgeMemo() throws -> [UInt64: Double] {
        let d = try json(evidenceDirectory + "/edges.memo.json") as! [String: Any]
        var memo: [UInt64: Double] = [:]
        for (key, value) in d["edges"] as! [String: Any] {
            memo[UInt64(key)!] = (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? .nan
        }
        return memo
    }

    static let grid = SD.TileGrid(widthPx: 2880, heightPx: 1800, tilesX: 90, tilesY: 57)
    static let durationMs = 15116
}

extension TrackingFixtures {
    /// Observations and samples joined and ordered the way the resolver orders them.
    static func joined(_ chunks: [SD.StoredChunk]? = nil) throws -> (observations: [SD.Observation], samples: [SD.ChangeSample]) {
        let chunks = try chunks ?? storedChunks()
        var reads: [SD.Observation] = []
        for chunk in chunks {
            for (index, read) in chunk.evidence.reads.enumerated() {
                let faces = chunk.faces?.facesByRead[index] ?? []
                reads.append(SD.Observation(timeMs: read.timeMs, region: read.region, faceRegion: read.faceRegion, lines: read.lines,
                                            findings: read.findings + faces, firstTile: read.firstTile, tileSignatures: read.tileSignatures))
            }
        }
        let observations = reads.enumerated().sorted { a, b in
            if a.element.timeMs != b.element.timeMs { return a.element.timeMs < b.element.timeMs }
            if a.element.region.minY != b.element.region.minY { return a.element.region.minY < b.element.region.minY }
            return a.offset < b.offset
        }.map(\.element)
        let samples = chunks.flatMap(\.evidence.changeSamples).sorted { $0.timeMs < $1.timeMs }
        return (observations, samples)
    }

    static func itemJSON(_ item: SD.TrackedItem) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = item.id
        d["kind"] = item.kind
        d["text"] = item.text
        d["key"] = item.key
        d["startMs"] = item.startMs
        d["endMs"] = item.endMs
        d["lastSeenMs"] = item.lastSeenMs
        let r = item.lastSeenRect
        d["lastSeenRect"] = [r.minX, r.minY, r.width, r.height]
        d["keyframes"] = item.keyframes.map { [Double($0.timeMs), $0.rect.origin.x, $0.rect.origin.y, $0.rect.size.width, $0.rect.size.height] }
        d["missedAtMs"] = item.missedAtMs ?? NSNull()
        d["endIfGoneMs"] = item.endIfGoneMs
        d["startEvidence"] = item.startEvidence.map { [$0.absentMs, $0.presentMs] } ?? NSNull()
        d["endEvidence"] = item.endEvidence.map { [$0.presentMs, $0.absentMs] } ?? NSNull()
        d["isTyped"] = item.isTyped
        d["exactStartMs"] = item.exactStartMs ?? NSNull()
        d["exactEndMs"] = item.exactEndMs ?? NSNull()
        d["heldKeyframes"] = item.heldKeyframes.map { $0.map { [$0.timeMs, $0.rect.origin.x, $0.rect.origin.y, $0.rect.size.width, $0.rect.size.height] } } ?? NSNull()
        return d
    }

    static func writeJSON(_ value: Any, _ path: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path))
    }
}

extension TrackingFixtures {
    static let facesDirectory = SDTestData.path("rgscan/evidence-json/c10/evidence-d4d6b001cc798cec7e4f")
    static let facesLayer = "faces-f54e69bb0293caa1447b"

    static func rectJSON(_ r: CGRect) -> Any { r.isNull ? NSNull() : [r.minX, r.minY, r.width, r.height] }

    static func findingJSON(_ f: SD.Finding) -> [String: Any] {
        ["kind": f.kind, "text": f.text, "key": f.key, "rect": rectJSON(f.rect)]
    }

    static func observationJSON(_ o: SD.Observation) -> [String: Any] {
        ["timeMs": o.timeMs, "region": rectJSON(o.region), "faceRegion": rectJSON(o.faceRegion),
         "lines": o.lines.map { ["text": $0.text, "key": $0.key, "rect": rectJSON($0.rect)] as [String: Any] },
         "findings": o.findings.map(findingJSON), "firstTile": o.firstTile,
         "tileSignatures": Data(o.tileSignatures).base64EncodedString()]
    }

    static func sampleJSON(_ s: SD.ChangeSample) -> [String: Any] {
        ["timeMs": s.timeMs, "isEverything": s.isEverything, "changedTiles": s.changedTiles.map { String($0) },
         "changedTileList": s.changedTileList, "signatures": s.signatures.map { Data($0).base64EncodedString() } ?? NSNull(),
         "stripeShiftsPx": s.stripeShiftsPx.map { Int($0) }]
    }
}
