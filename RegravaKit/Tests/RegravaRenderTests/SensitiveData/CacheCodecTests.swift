import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

/// Decodes every file of the reference caches and re-encodes it byte-identical (payload and file).
@Suite(.enabled(if: SDTestData.hasReference))
struct CacheCodecTests {
    static let roots = ["c8": SDTestData.path("rgscan/c8"), "c10": SDTestData.path("rgscan/c10")]

    static func files(under root: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root)
        var paths: [String] = []
        while let path = enumerator?.nextObject() as? String { paths.append(path) }
        return paths.sorted()
    }

    enum Kind { case evidence, faces, phrase, tracks, edges }

    static func kind(of path: String) -> Kind? {
        if path.hasSuffix(".evidence") { return .evidence }
        if path.hasSuffix("edges.memo") { return .edges }
        if path.hasSuffix(".tracks") { return .tracks }
        if path.hasSuffix(".layer") { return path.contains("/faces-") ? .faces : .phrase }
        return nil
    }

    static func version(of kind: Kind) -> Int {
        switch kind {
        case .evidence, .faces: 2
        case .phrase, .tracks, .edges: 1
        }
    }

    @Test func roundTripsReferenceCachesByteIdentical() throws {
        var count = 0
        for (_, root) in Self.roots {
            for path in Self.files(under: root) {
                guard let kind = Self.kind(of: path) else { continue }
                let file = try Data(contentsOf: URL(fileURLWithPath: root + "/" + path))
                let version = Self.version(of: kind)
                let payload = try SD.EvidenceFile.decode(file, version: version)
                let reencoded: Data
                switch kind {
                case .evidence: reencoded = try SD.ChunkEvidence(decoding: payload).encoded()
                case .faces: reencoded = try SD.ChunkFaces(decoding: payload).encoded()
                case .phrase: reencoded = try SD.ChunkPhrase(decoding: payload).encoded()
                case .tracks: reencoded = SD.SensitiveDataCache.encodeFaceTracks(try SD.SensitiveDataCache.decodeFaceTracks(payload))
                case .edges: reencoded = SD.SensitiveDataCache.encodeEdges(try SD.SensitiveDataCache.decodeEdges(payload))
                }
                #expect(reencoded == payload, "payload \(root)/\(path)")
                let refile = try SD.EvidenceFile.encode(reencoded, version: version)
                #expect(refile == file, "file \(root)/\(path)")
                count += 1
            }
        }
        #expect(count == 20)
    }

    @Test func decodeErrors() throws {
        #expect(throws: SD.EvidenceDecodingError.self) { try SD.EvidenceFile.decode(Data([1, 2, 3]), version: 2) }
        let good = try SD.EvidenceFile.encode(Data([1, 2, 3, 4]), version: 2)
        do { _ = try SD.EvidenceFile.decode(good, version: 1); Issue.record("no throw") } catch let error as SD.EvidenceDecodingError {
            #expect(error.reason == "another version")
        }
        var bad = good
        bad[20] ^= 1
        do { _ = try SD.EvidenceFile.decode(bad, version: 2); Issue.record("no throw") } catch let error as SD.EvidenceDecodingError {
            #expect(error.reason == "checksum")
        }
        #expect(try SD.EvidenceFile.decode(good, version: 2) == Data([1, 2, 3, 4]))
    }

    // MARK: JSON dump for the other components

    static func json(_ rect: CGRect) -> Any {
        rect.isNull ? NSNull() : [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    static func json(_ finding: SD.Finding) -> Any {
        ["kind": finding.kind, "text": finding.text, "key": finding.key, "rect": json(finding.rect)]
    }

    static func json(_ evidence: SD.ChunkEvidence) -> Any {
        [
            "chunkIndex": evidence.chunkIndex,
            "changeSamples": evidence.changeSamples.map { sample -> Any in
                [
                    "timeMs": sample.timeMs, "isEverything": sample.isEverything,
                    "changedTiles": sample.changedTiles.map { String($0) },
                    "changedTileList": sample.changedTileList,
                    "signatures": sample.signatures.map { $0.map { Int($0) } as Any } ?? NSNull(),
                    "stripeShiftsPx": sample.stripeShiftsPx.map { Int($0) },
                ] as [String: Any]
            },
            "sampledTimesMs": evidence.sampledTimesMs,
            "reads": evidence.reads.map { read -> Any in
                [
                    "timeMs": read.timeMs, "region": json(read.region), "faceRegion": json(read.faceRegion),
                    "lines": read.lines.map { ["text": $0.text, "key": $0.key, "rect": json($0.rect)] as [String: Any] },
                    "findings": read.findings.map(json), "firstTile": read.firstTile,
                    "tileSignatures": read.tileSignatures.map { Int($0) },
                ] as [String: Any]
            },
            "readHasPhotos": evidence.readHasPhotos,
        ] as [String: Any]
    }

    static func json(_ track: SD.FaceTrack) -> Any {
        [
            "startMs": track.startMs, "endMs": track.endMs,
            "path": track.path.map { ["timeMs": $0.timeMs, "point": [Double($0.point.x), Double($0.point.y)]] as [String: Any] },
            "boxes": track.boxes.map { ["timeMs": $0.timeMs, "rect": json($0.rect)] as [String: Any] },
            "isLostAtStart": track.isLostAtStart, "isLostAtEnd": track.isLostAtEnd,
        ] as [String: Any]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SD_DUMP_EVIDENCE"] == "1")) func dumpEvidenceJSON() throws {
        let out = SDTestData.path("rgscan/evidence-json")
        for (name, root) in Self.roots {
            for path in Self.files(under: root) {
                guard let kind = Self.kind(of: path) else { continue }
                let file = try Data(contentsOf: URL(fileURLWithPath: root + "/" + path))
                let payload = try SD.EvidenceFile.decode(file, version: Self.version(of: kind))
                let object: Any
                switch kind {
                case .evidence: object = Self.json(try SD.ChunkEvidence(decoding: payload))
                case .faces:
                    object = ["facesByRead": try SD.ChunkFaces(decoding: payload).facesByRead.map { $0.map(Self.json) }]
                case .phrase:
                    let phrase = try SD.ChunkPhrase(decoding: payload)
                    object = ["findingsByRead": Dictionary(uniqueKeysWithValues: phrase.findingsByRead.map { (String($0.key), $0.value.map(Self.json)) })]
                case .tracks: object = ["tracks": try SD.SensitiveDataCache.decodeFaceTracks(payload).map(Self.json)]
                case .edges:
                    let edges = try SD.SensitiveDataCache.decodeEdges(payload)
                    object = ["edges": Dictionary(uniqueKeysWithValues: edges.map { (String($0.key), $0.value) })]
                }
                let target = URL(fileURLWithPath: "\(out)/\(name)/\(path).json")
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: target)
            }
        }
    }
}

@Suite(.enabled(if: SDTestData.hasReference))
struct SensitiveDataCacheTests {
    @Test func reproducesReferenceEvidenceDirectoryAndManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sdA-cache-\(UUID().uuidString)", isDirectory: true)
        let grid = SD.ChunkGrid.forVideo(durationMs: 15116, lanes: 8)
        #expect(grid.description == "4000,8000,12000,15116")
        let options = SD.Options()
        #expect(options.evidenceParameters == "50|120|300|400|500|20|enlarged")
        let cache = try SD.SensitiveDataCache(videoPath: SDTestData.path("rgscan/clip15.mov"), root: root, durationMs: 15116, widthPx: 2880,
                                              heightPx: 1800, grid: grid, parameters: options.evidenceParameters)
        #expect(cache.directory.lastPathComponent == "evidence-d4d6b001cc798cec7e4f")
        let ours = try Data(contentsOf: cache.directory.appendingPathComponent("manifest.json"))
        let reference = try Data(contentsOf: URL(fileURLWithPath: SDTestData.path("rgscan/c8/evidence-d4d6b001cc798cec7e4f/manifest.json")))
        // JSONEncoder's key order follows the per-process hash seed (the two reference caches differ in
        // order too): compare the objects and the byte count (same escaping, no whitespace).
        #expect(ours.count == reference.count)
        let a = try JSONSerialization.jsonObject(with: ours) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: reference) as? NSDictionary
        #expect(a == b)
        #expect(String(decoding: ours, as: UTF8.self).contains("\\/tmp\\/rgscan"))
        #expect(FileManager.default.fileExists(atPath: cache.directory.appendingPathComponent("claims").path))
        // Claims.
        #expect(cache.claim(3))
        #expect(!cache.claim(3))
        cache.release(3)
        #expect(cache.claim(3))
        cache.release(3)
        // Evidence round trip through the cache.
        let file = try Data(contentsOf: URL(fileURLWithPath: SDTestData.path("rgscan/c8/evidence-d4d6b001cc798cec7e4f/chunk-000001.evidence")))
        try file.write(to: cache.evidenceURL(1))
        #expect(cache.readEvidence(1)?.chunkIndex == 1)
        try file.write(to: cache.evidenceURL(2))
        #expect(cache.readEvidence(2) == nil)                     // index mismatch: nil, file kept
        #expect(FileManager.default.fileExists(atPath: cache.evidenceURL(2).path))
        try Data([1, 2, 3]).write(to: cache.evidenceURL(0))
        #expect(cache.readEvidence(0) == nil)                     // undecodable: removed
        #expect(!FileManager.default.fileExists(atPath: cache.evidenceURL(0).path))
        // Edges merge.
        try cache.writeEdges([1: 1.5, 2: 2.5])
        try cache.writeEdges([2: 3.5, 7: 0.25])
        #expect(cache.readEdges() == [1: 1.5, 2: 3.5, 7: 0.25])
    }
}
