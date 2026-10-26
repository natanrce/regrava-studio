import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

/// Deterministic random numbers for generated cases.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Variations of the stored clip15 reads (dropped reads and findings, moved and resized findings,
/// edited keys, injected scroll shifts and changed tiles, other options) used to compare tracking
/// results case by case. `writeCases` writes the inputs; a reference run fills in `<case>.orig.json`;
/// `compareCases` tracks each input and compares.
@Suite("Tracking generated cases", .enabled(if: SDTestData.hasReference))
struct TrackingFuzzTests {
    static let directory = SDTestData.path("C-work/fuzz")
    static let caseCount = Int(ProcessInfo.processInfo.environment["C_FUZZ_CASES"] ?? "40")!
    static let seedOffset = Int(ProcessInfo.processInfo.environment["C_FUZZ_SEED"] ?? "0")!

    static func mutated(seed: UInt64, base: (observations: [SD.Observation], samples: [SD.ChangeSample])) -> [String: Any] {
        var rng = SplitMix64(state: seed)
        func chance(_ p: Double) -> Bool { Double.random(in: 0 ..< 1, using: &rng) < p }
        let keep = [1.0, 0.95, 0.85, 0.7].randomElement(using: &rng)!
        let jitter = [0.0, 0.1, 0.3].randomElement(using: &rng)!
        let editKeys = [0.0, 0.05, 0.15].randomElement(using: &rng)!
        let dropFindings = [0.0, 0.05, 0.2].randomElement(using: &rng)!
        let shiftSamples = [0.0, 0.1, 0.3].randomElement(using: &rng)!
        let flipTiles = [0.0, 0.1, 0.3].randomElement(using: &rng)!
        let noise = [0.0, 0.0, 0.2].randomElement(using: &rng)!
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var observations: [SD.Observation] = []
        for o in base.observations where chance(keep) {
            var findings: [SD.Finding] = []
            for f in o.findings where !chance(dropFindings) {
                var rect = f.rect
                if chance(jitter) {
                    rect = CGRect(x: rect.minX + Double(Int.random(in: -6 ... 6, using: &rng)),
                                  y: rect.minY + Double(Int.random(in: -6 ... 6, using: &rng)),
                                  width: rect.width * Double.random(in: 0.85 ... 1.15, using: &rng),
                                  height: rect.height * Double.random(in: 0.85 ... 1.15, using: &rng))
                }
                var key = f.key
                if chance(editKeys) && !key.isEmpty {
                    var chars = Array(key)
                    chars[Int.random(in: 0 ..< chars.count, using: &rng)] = alphabet.randomElement(using: &rng)!
                    key = String(chars)
                }
                findings.append(SD.Finding(kind: f.kind, text: f.text, key: key, rect: rect))
            }
            var signatures = o.tileSignatures
            if noise > 0 {
                for _ in 0 ..< 2000 where chance(noise) {
                    let i = Int.random(in: 0 ..< signatures.count, using: &rng)
                    signatures[i] = UInt8(clamping: Int(signatures[i]) + Int.random(in: -40 ... 40, using: &rng))
                }
            }
            observations.append(SD.Observation(timeMs: o.timeMs, region: o.region, faceRegion: o.faceRegion, lines: o.lines,
                                               findings: findings, firstTile: o.firstTile, tileSignatures: signatures))
        }
        var samples: [SD.ChangeSample] = []
        for s in base.samples {
            var shifts = s.stripeShiftsPx
            if !s.isEverything && shifts.count == 8 && chance(shiftSamples) {
                let stripe = Int.random(in: 0 ..< 8, using: &rng)
                shifts[stripe] = [Int16.min, 0, Int16(Int.random(in: -400 ... 400, using: &rng)),
                                  Int16(8 * Int.random(in: -60 ... 60, using: &rng))].randomElement(using: &rng)!
            }
            var tiles = s.changedTiles
            var list = s.changedTileList
            if !s.isEverything && !tiles.isEmpty && chance(flipTiles) {
                // Clear some changed tiles (their stored signatures stay consistent with the list).
                for _ in 0 ..< 40 {
                    let tile = Int.random(in: 0 ..< tiles.count * 64, using: &rng)
                    if !list.contains(tile) { tiles[tile >> 6] |= 1 << UInt64(tile & 63) }
                }
            }
            if !s.isEverything && chance(flipTiles * 0.5) {
                tiles = tiles.map { _ in 0 }
                list = list.filter { _ in false }
            }
            let signatures = list.isEmpty && !s.isEverything ? s.signatures.map { _ in [UInt8]() } : s.signatures
            samples.append(SD.ChangeSample(timeMs: s.timeMs, isEverything: s.isEverything, changedTiles: tiles,
                                           changedTileList: list, signatures: signatures, stripeShiftsPx: shifts))
        }
        // A scroll: every stripe shifts for a while, the findings of later reads move with it.
        if chance(0.5) {
            let t0 = Int.random(in: 500 ... 12000, using: &rng)
            let t1 = t0 + Int.random(in: 100 ... 2500, using: &rng)
            let px = [1, 2, 3, 5, 8, 20, -4, -12, 40].randomElement(using: &rng)!
            let fractional = chance(0.3)
            var total = 0.0
            var offsets: [(timeMs: Int, total: Double)] = []
            for (i, s) in samples.enumerated() where !s.isEverything && s.timeMs >= t0 && s.timeMs <= t1 {
                let units = fractional ? Int16(px * 8 + Int.random(in: -3 ... 3, using: &rng)) : Int16(px * 8)
                let allTiles = chance(0.8)
                samples[i] = SD.ChangeSample(timeMs: s.timeMs, isEverything: false,
                                             changedTiles: allTiles ? s.changedTiles.map { _ in UInt64.max } : s.changedTiles,
                                             changedTileList: s.changedTileList, signatures: s.signatures,
                                             stripeShiftsPx: [Int16](repeating: units, count: 8))
                total += Double(units) / 8
                offsets.append((s.timeMs, total))
            }
            if chance(0.8) {
                observations = observations.map { o in
                    let moved = offsets.last(where: { $0.timeMs <= o.timeMs })?.total ?? 0
                    if moved == 0 { return o }
                    return SD.Observation(timeMs: o.timeMs, region: o.region, faceRegion: o.faceRegion,
                                          lines: o.lines.map { SD.RecognizedLine(text: $0.text, key: $0.key, rect: $0.rect.offsetBy(dx: 0, dy: -moved)) },
                                          findings: o.findings.map { SD.Finding(kind: $0.kind, text: $0.text, key: $0.key, rect: $0.rect.offsetBy(dx: 0, dy: -moved)) },
                                          firstTile: o.firstTile, tileSignatures: o.tileSignatures)
                }
            }
        }
        // Content that is covered and comes back: the tiles under a finding change to something
        // else, then back to how they looked when it was read.
        for _ in 0 ..< [0, 1, 3].randomElement(using: &rng)! {
            guard let o = observations.filter({ !$0.findings.isEmpty }).randomElement(using: &rng),
                  let f = o.findings.randomElement(using: &rng) else { break }
            let grid = SD.TileGrid(widthPx: 2880, heightPx: 1800, tilesX: 90, tilesY: 57)
            let tiles = grid.tiles(in: f.rect)
            let later = samples.indices.filter { !samples[$0].isEverything && samples[$0].timeMs > o.timeMs }
            guard later.count >= 4 else { break }
            let k1 = later[Int.random(in: 0 ..< later.count / 2, using: &rng)]
            let k2 = later.filter { $0 > k1 }.randomElement(using: &rng)!
            func look(_ tile: Int) -> [UInt8] {
                let a = (tile - o.firstTile) * 16
                guard a >= 0, a + 16 <= o.tileSignatures.count else { return [UInt8](repeating: 0, count: 16) }
                return Array(o.tileSignatures[a ..< a + 16])
            }
            let garbage = UInt8.random(in: 0 ... 255, using: &rng)
            samples[k1] = Self.adding(tiles, to: samples[k1]) { _ in [UInt8](repeating: garbage, count: 16) }
            let k3 = later.filter { $0 > k2 }.randomElement(using: &rng)
            samples[k2] = Self.adding(tiles, to: samples[k2], look)
            if let k3, chance(0.5) {
                samples[k3] = Self.adding(tiles, to: samples[k3]) { _ in [UInt8](repeating: garbage &+ 77, count: 16) }
            }
        }
        let duration = [15116, 15116, 9000, 20000].randomElement(using: &rng)!
        return [
            "observations": observations.map(TrackingFixtures.observationJSON),
            "samples": samples.map(TrackingFixtures.sampleJSON),
            "grid": [2880, 1800, 90, 57],
            "durationMs": duration,
            "sampleMs": [50, 50, 100].randomElement(using: &rng)!,
            "changeThreshold": [20, 20, 8, 40].randomElement(using: &rng)!,
        ]
    }

    /// `sample` with `tiles` marked changed, storing `signature(tile)` for them.
    static func adding(_ tiles: [Int], to sample: SD.ChangeSample, _ signature: (Int) -> [UInt8]) -> SD.ChangeSample {
        var changed = sample.changedTiles
        var stored: [Int: [UInt8]] = [:]
        if let signatures = sample.signatures {
            for (i, tile) in sample.changedTileList.enumerated() where (i + 1) * 16 <= signatures.count {
                stored[tile] = Array(signatures[i * 16 ..< i * 16 + 16])
            }
        }
        for tile in tiles {
            while changed.count <= tile >> 6 { changed.append(0) }
            changed[tile >> 6] |= 1 << UInt64(tile & 63)
            stored[tile] = signature(tile)
        }
        let list = stored.keys.sorted()
        return SD.ChangeSample(timeMs: sample.timeMs, isEverything: false, changedTiles: changed, changedTileList: list,
                               signatures: list.flatMap { stored[$0]! }, stripeShiftsPx: sample.stripeShiftsPx)
    }

    @Test("write generated inputs", .enabled(if: ProcessInfo.processInfo.environment["SD_WRITE_FUZZ"] == "1"))
    func writeCases() throws {
        try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        let plain = try TrackingFixtures.joined()
        let faces = try TrackingFixtures.joined(TrackingFixtures.storedChunks(TrackingFixtures.facesDirectory, facesLayer: TrackingFixtures.facesLayer))
        for n in 0 ..< Self.caseCount {
            let base = n % 2 == 0 ? plain : faces
            let input = Self.mutated(seed: UInt64(n + Self.seedOffset) &* 7919 &+ 17, base: base)
            try TrackingFixtures.writeJSON(input, String(format: "%@/case-%03d.in.json", Self.directory, n))
        }
    }

    @Test("generated inputs track like the reference")
    func compareCases() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory).filter { $0.hasSuffix(".orig.json") }.sorted()
        var failures: [String] = []
        for name in names {
            let input = try TrackingFixtures.json(Self.directory + "/" + name.replacingOccurrences(of: ".orig.json", with: ".in.json")) as! [String: Any]
            let observations = (input["observations"] as! [Any]).map(TrackingFixtures.observation)
            let samples = (input["samples"] as! [Any]).map(TrackingFixtures.sample)
            let g = input["grid"] as! [Int]
            var options = SD.Options()
            options.sampleMs = input["sampleMs"] as! Int
            options.changeThreshold = input["changeThreshold"] as! Int
            let tracker = SD.Tracker(observations: observations, timeline: SD.ChangeTimeline(samples: samples),
                                     grid: SD.TileGrid(widthPx: g[0], heightPx: g[1], tilesX: g[2], tilesY: g[3]),
                                     options: options, durationMs: input["durationMs"] as! Int)
            let items = tracker.track()
            let minePath = Self.directory + "/" + name.replacingOccurrences(of: ".orig.json", with: ".mine.json")
            try TrackingFixtures.writeJSON(items.map(TrackingFixtures.itemJSON), minePath)
            let mine = try TrackingFixtures.json(minePath) as! NSArray
            let reference = try TrackingFixtures.json(Self.directory + "/" + name) as! NSArray
            if mine != reference { failures.append(name) }
        }
        #expect(!names.isEmpty)
        #expect(failures.isEmpty, "\(failures.count)/\(names.count) differ: \(failures)")
    }
}
