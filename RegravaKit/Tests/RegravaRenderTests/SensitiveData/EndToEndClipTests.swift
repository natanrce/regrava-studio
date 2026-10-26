import Foundation
import Testing
@testable import RegravaRender

/// The whole scan of the 15 s reference clip against the reference scan's detections (ids, kinds,
/// texts, times, keyframes). SD_E2E_OUT=/path.json writes the output instead
/// ([SD_E2E_PHRASES=a|b] [SD_E2E_CASCADE=path] [SD_E2E_DEMAND=ms] [SD_E2E_CACHE=dir]).
@Suite(.serialized) struct EndToEndClipTests {
    static let cascade = SensitiveDataScanner.bundledCascadePath ?? ""

    static func run(phrases: [String], cascade: String?, demandMs: Int?, cache: String?) throws -> (SD.ScanOutput, [[String: Any]]) {
        var options = SD.Options()
        options.videoPath = ProcessInfo.processInfo.environment["SD_E2E_VIDEO"] ?? SDTestData.clip
        options.customPhrases = phrases
        options.faceCascadePath = cascade
        options.cacheRoot = URL(fileURLWithPath: cache ?? NSTemporaryDirectory() + "sd-e2e-\(UUID().uuidString)", isDirectory: true)
        options.demandMs = demandMs
        var partials: [[String: Any]] = []
        let lock = NSLock()
        let output = try SD.runSensitiveDataScan(options, isCancelled: { false }, onPartialResult: { p in
            lock.lock()
            defer { lock.unlock() }
            var entry: [String: Any] = ["finalUpToMs": p.finalUpToMs, "analyzedUpToMs": p.analyzedUpToMs, "count": p.detections.count]
            if let island = p.provisional { entry["provisional"] = ["fromMs": island.fromMs, "toMs": island.toMs, "count": island.detections.count] }
            partials.append(entry)
        })
        return (output, partials)
    }

    static func normalized(_ value: Any) -> NSObject {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try! JSONSerialization.jsonObject(with: data) as! NSObject
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SD_E2E_OUT"] != nil)) func writesTheClipScan() throws {
        let env = ProcessInfo.processInfo.environment
        let (output, partials) = try Self.run(phrases: env["SD_E2E_PHRASES"].map { $0.components(separatedBy: "|") } ?? [],
                                              cascade: env["SD_E2E_CASCADE"], demandMs: env["SD_E2E_DEMAND"].flatMap { Int($0) },
                                              cache: env["SD_E2E_CACHE"])
        let result: [String: Any] = ["detections": output.detections, "stats": output.stats, "finalUpToMs": output.finalUpToMs,
                                     "analyzedUpToMs": output.analyzedUpToMs, "partials": partials]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: env["SD_E2E_OUT"]!))
    }

    @Test(.enabled(if: SDTestData.hasReference && SDTestData.runsLongTests)) func defaultScanMatchesTheReference() throws {
        let (output, _) = try Self.run(phrases: [], cascade: nil, demandMs: nil, cache: nil)
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: SDTestData.path("rgscan/orig_noface.json")))) as! [String: Any]
        #expect(Self.normalized(output.detections) == Self.normalized(reference["detections"]!))
    }

    @Test(.enabled(if: SDTestData.hasReference && SDTestData.runsLongTests && FileManager.default.fileExists(atPath: cascade)))
    func phraseAndFaceScanMatchesTheReference() throws {
        let (output, _) = try Self.run(phrases: ["Natan"], cascade: Self.cascade, demandMs: nil, cache: nil)
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: SDTestData.path("rgscan/orig_full.json")))) as! [String: Any]
        #expect(Self.normalized(output.detections) == Self.normalized(reference["detections"]!))
    }
}
