import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

/// Runs the chunk scan on the 15 s reference clip and compares sampling, change samples and read
/// geometry with the stored reference evidence. Text is not read here (empty lines), so lines and
/// findings are not compared.
@Suite(.serialized, .enabled(if: SDTestData.hasReference && SDTestData.runsLongTests)) struct ScanChunkClipTests {
    static let clip = SDTestData.path("rgscan/clip15.mov")
    static let evidenceDir: String? = {
        let base = SDTestData.path("rgscan/evidence-json/c8")
        guard let dir = try? FileManager.default.contentsOfDirectory(atPath: base).first(where: { $0.hasPrefix("evidence-") }) else { return nil }
        return base + "/" + dir
    }()

    func rect(_ v: Any) -> CGRect? {
        guard let a = v as? [Double] else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    @Test func chunksMatchReferenceEvidence() throws {
        guard let dir = Self.evidenceDir, FileManager.default.fileExists(atPath: Self.clip) else { return }
        var options = SD.Options()
        options.videoPath = Self.clip
        let scanner = try SD.Scanner(options: options)
        let ends = [4000, 8000, 12000, 15116]
        var report: [String] = []
        for chunk in 0..<4 {
            let start = chunk == 0 ? 0 : ends[chunk - 1]
            let scan = try scanner.readAdmission.scanning(chunk) {
                try scanner.scanChunk(chunk, startMs: start, endMs: ends[chunk], layers: SD.ChunkLayers(faceLayer: nil, phrases: []))
            }
            let url = URL(fileURLWithPath: dir + String(format: "/chunk-%06d.evidence.json", chunk))
            let ref = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let e = scan.evidence
            let refTimes = ref["sampledTimesMs"] as! [Int]
            if refTimes != e.sampledTimesMs {
                let i = Array(zip(refTimes, e.sampledTimesMs)).firstIndex { $0.0 != $0.1 } ?? min(refTimes.count, e.sampledTimesMs.count)
                report.append("chunk \(chunk) sampledTimesMs differ at \(i): ref \(refTimes.count) \(Array(refTimes[max(0, i - 2)..<min(refTimes.count, i + 3)])) port \(e.sampledTimesMs.count) \(Array(e.sampledTimesMs[max(0, i - 2)..<min(e.sampledTimesMs.count, i + 3)]))")
            }
            // The reference evidence holds unset bytes for the block rows below the frame (they are
            // never computed): compare only computed bytes, and skip reference samples whose changes
            // are only there.
            let grid = scanner.grid
            let lastRow = grid.tilesY - 1
            let computedRows = ((grid.heightPx + 7) / 8) - lastRow * 4
            func isComputed(_ tile: Int, _ j: Int) -> Bool { tile / grid.tilesX != lastRow || j / 4 < computedRows }
            func masked(_ sigs: [UInt8], firstTile: Int) -> [UInt8] {
                sigs.enumerated().map { isComputed(firstTile + $0.offset / 16, $0.offset % 16) ? $0.element : 0 }
            }
            let portTimes = Set(e.changeSamples.map(\.timeMs))
            let refSamples = (ref["changeSamples"] as! [[String: Any]]).filter { r in
                let list = r["changedTileList"] as! [Int]
                let onlyUnset = !list.isEmpty && list.allSatisfy { $0 / grid.tilesX == lastRow } && !portTimes.contains(r["timeMs"] as! Int)
                if onlyUnset { report.append("note: chunk \(chunk) reference sample @\(r["timeMs"]!) changes only unset bytes (skipped)") }
                return !onlyUnset
            }
            if refSamples.count != e.changeSamples.count { report.append("chunk \(chunk) samples \(refSamples.count) vs \(e.changeSamples.count)") }
            for (i, (r, p)) in zip(refSamples, e.changeSamples).enumerated() {
                var why: [String] = []
                if r["timeMs"] as! Int != p.timeMs { why.append("time \(r["timeMs"]!) vs \(p.timeMs)") }
                if r["isEverything"] as! Bool != p.isEverything { why.append("isEverything") }
                if (r["changedTiles"] as! [String]).map({ UInt64($0)! }) != p.changedTiles { why.append("changedTiles") }
                if r["changedTileList"] as! [Int] != p.changedTileList { why.append("list \((r["changedTileList"] as! [Int]).count) vs \(p.changedTileList.count)") }
                let refSigs = (r["signatures"] as? [Int])?.map(UInt8.init)
                if let refSigs, let ps = p.signatures {
                    let list = p.changedTileList
                    let refList = r["changedTileList"] as! [Int]
                    let a = refSigs.enumerated().map { $0.offset / 16 < refList.count && isComputed(refList[$0.offset / 16], $0.offset % 16) ? $0.element : 0 }
                    let b = ps.enumerated().map { $0.offset / 16 < list.count && isComputed(list[$0.offset / 16], $0.offset % 16) ? $0.element : 0 }
                    if a != b { why.append("signatures") }
                } else if (refSigs == nil) != (p.signatures == nil) { why.append("signatures nil") }
                if (r["stripeShiftsPx"] as! [Int]).map(Int16.init) != p.stripeShiftsPx { why.append("shifts \(r["stripeShiftsPx"]!) vs \(p.stripeShiftsPx)") }
                if !why.isEmpty {
                    report.append("chunk \(chunk) sample \(i) @\(p.timeMs): " + why.joined(separator: ", "))
                    break
                }
            }
            let refReads = ref["reads"] as! [[String: Any]]
            if refReads.count != e.reads.count { report.append("chunk \(chunk) reads \(refReads.count) vs \(e.reads.count)") }
            for (i, (r, p)) in zip(refReads, e.reads).enumerated() {
                var why: [String] = []
                if r["timeMs"] as! Int != p.timeMs { why.append("time \(r["timeMs"]!) vs \(p.timeMs)") }
                if rect(r["region"]!) != p.region { why.append("region \(r["region"]!) vs \(p.region)") }
                if rect(r["faceRegion"]!) != p.faceRegion { why.append("faceRegion") }
                if r["firstTile"] as! Int != p.firstTile { why.append("firstTile") }
                if masked((r["tileSignatures"] as! [Int]).map(UInt8.init), firstTile: p.firstTile) != masked(p.tileSignatures, firstTile: p.firstTile) { why.append("tileSignatures") }
                if !why.isEmpty {
                    report.append("chunk \(chunk) read \(i): " + why.joined(separator: ", "))
                    break
                }
            }
            print("chunk \(chunk): sampled \(e.sampledTimesMs.count)/\(refTimes.count) samples \(e.changeSamples.count)/\(refSamples.count) reads \(e.reads.count)/\(refReads.count)")
        }
        let s = scanner.stats
        print("stats decoded \(s.decodedFrames) skipped \(s.skippedFrames) events \(s.eventFrames) sampled \(s.sampledFrames) samples \(s.changeSamples) reads \(s.ocrJobs) full \(s.ocrFullFrameJobs)")
        for line in report { print(line) }
        #expect(report.allSatisfy { $0.hasPrefix("note:") })
    }
}
