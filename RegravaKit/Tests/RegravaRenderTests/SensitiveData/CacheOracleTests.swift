import Foundation
import Testing
@testable import RegravaRender

/// Compares against reference outputs recorded in /tmp/A-oracle/out*.json.
@Suite(.enabled(if: SDTestData.hasReference))
struct CacheReferenceTests {
    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: SDTestData.path("A-oracle/") + name))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func chunkGridForVideo() throws {
        let cases = try Self.load("out.json")["forVideo"] as! [[Any]]
        #expect(cases.count > 300)
        for c in cases {
            let d = c[0] as! Int, lanes = c[1] as! Int, ends = c[2] as! [Int]
            #expect(SD.ChunkGrid.forVideo(durationMs: d, lanes: lanes).endsMs == ends, "\(d) \(lanes)")
        }
    }

    @Test func sweepOrder() throws {
        let cases = try Self.load("out.json")["order"] as! [[Any]]
        for c in cases {
            let count = c[0] as! Int, demand = c[1] as? Int, order = c[2] as! [Int]
            #expect(SD.ChunkSweep.order(chunkCount: count, demandChunk: demand) == order, "\(count) \(String(describing: demand))")
        }
    }

    @Test func hashesAndDescriptions() throws {
        let out = try Self.load("out.json")
        for c in out["shortHash"] as! [[Any]] { #expect(SD.shortHash(c[0] as! String) == c[1] as! String) }
        for c in out["fnv1a64"] as! [[Any]] {
            #expect(String(SD.fnv1a64(Data(base64Encoded: c[0] as! String)!)) == c[1] as! String)
        }
        for c in out["description"] as! [[Any]] { #expect(SD.ChunkGrid(endsMs: c[0] as! [Int]).description == c[1] as! String) }
    }

    /// The recorded paths use this project bundle extension.
    static let recordedBundleExtension = "screenstudio"

    @Test func videoKeyAndRoot() throws {
        FileManager.default.changeCurrentDirectoryPath(SDTestData.path("A-oracle"))
        for c in try Self.load("out.json")["videoKey"] as! [[Any]] {
            let path = c[0] as! String
            #expect(SD.SensitiveDataCache.videoKey(forVideoAt: path, bundleExtension: Self.recordedBundleExtension) == c[1] as! String, "\(path)")
            #expect(SD.SensitiveDataCache.root(forVideoAt: path, bundleExtension: Self.recordedBundleExtension).absoluteString == c[2] as! String, "\(path)")
        }
    }

    @Test func evidenceParameters() throws {
        for c in try Self.load("out.json")["evidenceParameters"] as! [[Any]] {
            var o = SD.Options()
            o.sampleMs = c[0] as! Int; o.settleMs = c[1] as! Int; o.maxDirtyMs = c[2] as! Int; o.minRereadMs = c[3] as! Int
            o.maxScrollingDirtyMs = c[4] as! Int; o.changeThreshold = c[5] as! Int; o.enlargesSmallText = c[6] as! Bool
            #expect(o.evidenceParameters == c[7] as! String)
        }
    }

    static func describe(_ o: SD.Options) -> [String: String] {
        ["decodeThreads": "\(o.decodeThreads)", "ocrWorkers": "\(o.ocrWorkers)", "sampleMs": "\(o.sampleMs)",
         "settleMs": "\(o.settleMs)", "maxDirtyMs": "\(o.maxDirtyMs)", "minRereadMs": "\(o.minRereadMs)",
         "maxScrollingDirtyMs": "\(o.maxScrollingDirtyMs)", "changeThreshold": "\(o.changeThreshold)",
         "isTextRedacted": "\(o.isTextRedacted)", "chunkMs": o.chunkMs.map { "\($0)" } ?? "nil",
         "cacheRoot": o.cacheRoot?.absoluteString ?? "nil", "enlargesSmallText": "\(o.enlargesSmallText)",
         "partialFinalLagMs": "\(o.partialFinalLagMs)", "videoPath": o.videoPath]
    }

    static func describe(_ d: [String: Any]) -> [String: String] {
        d.mapValues { v in
            if v is NSNull { return "nil" }
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return "\(v)"
        }
    }

    @Test func optionsDefaultsAndEnvironment() throws {
        let names = ["SENSITIVE_DATA_SCROLLING_DIRTY_MS", "SENSITIVE_DATA_CHUNK_MS", "SENSITIVE_DATA_CACHE_ROOT",
                     "SENSITIVE_DATA_ENLARGE_SMALL_TEXT"]
        let sets: [(String, [String: String])] = [
            ("out.json", [:]),
            ("out-env.json", ["SENSITIVE_DATA_SCROLLING_DIRTY_MS": "777", "SENSITIVE_DATA_CHUNK_MS": "+6000",
                              "SENSITIVE_DATA_CACHE_ROOT": "/tmp/zz/root", "SENSITIVE_DATA_ENLARGE_SMALL_TEXT": "0"]),
            ("out-env2.json", ["SENSITIVE_DATA_SCROLLING_DIRTY_MS": " 9", "SENSITIVE_DATA_CHUNK_MS": "abc",
                               "SENSITIVE_DATA_ENLARGE_SMALL_TEXT": "00"]),
        ]
        for (file, env) in sets {
            for name in names { unsetenv(name) }
            for (k, v) in env { setenv(k, v, 1) }
            let expected = Self.describe(try Self.load(file)["options"] as! [String: Any])
            #expect(Self.describe(SD.Options()) == expected, "\(file)")
        }
        for name in names { unsetenv(name) }
    }
}
