import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

// Compares text reading with reference outputs recorded under the reference data (B-oracle/out).

private struct Reference {
    let json: [String: Any]
    let blob: Data

    init?(_ dir: String) {
        guard let j = try? Data(contentsOf: URL(fileURLWithPath: dir + "/out.json")),
              let b = try? Data(contentsOf: URL(fileURLWithPath: dir + "/blob.bin")),
              let o = try? JSONSerialization.jsonObject(with: j) as? [String: Any] else { return nil }
        json = o
        blob = b
    }

    func bytes(_ ref: Any?) -> Data {
        let r = ref as! [Int]
        return blob.subdata(in: r[0]..<(r[0] + r[1]))
    }

    func image(_ any: Any?) -> SD.GrayImage? {
        guard let d = any as? [String: Any] else { return nil }
        let data = bytes(d["bytes"])
        let w = d["w"] as! Int, h = d["h"] as! Int
        let cg = SD.grayCGImage(data, width: w, height: h)!
        return SD.GrayImage(bytes: data, widthPx: w, heightPx: h, originPx: CGPoint(x: d["ox"] as! Double, y: d["oy"] as! Double), cgImage: cg)
    }
}

private func rect(_ any: Any?) -> CGRect {
    guard let a = any as? [Double] else { return .null }
    return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
}

private func same(_ a: SD.GrayImage?, _ b: SD.GrayImage?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?):
        return x.bytes == y.bytes && x.widthPx == y.widthPx && x.heightPx == y.heightPx && x.originPx == y.originPx
            && x.cgImage.width == y.cgImage.width && x.cgImage.height == y.cgImage.height && x.cgImage.bytesPerRow == y.cgImage.bytesPerRow
    default: return false
    }
}

private func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
    if a.isNull || b.isNull { return a.isNull && b.isNull }
    return a.origin.x == b.origin.x && a.origin.y == b.origin.y && a.size.width == b.size.width && a.size.height == b.size.height
}

private let pure = Reference(SDTestData.path("B-oracle/out/pure"))

@Suite(.serialized, .enabled(if: SDTestData.hasReference)) struct TextReadingPureTests {
    @Test func imageOperationsMatchReference() throws {
        let ref = try #require(pure)
        let images = (ref.json["images"] as! [Any]).map { ref.image($0)! }
        var count = 0
        for c in ref.json["withLocalContrast"] as! [[String: Any]] {
            let input = ref.image(c["in"])!
            #expect(same(input.withLocalContrast(isDimmedOnly: c["dimmed"] as! Bool), ref.image(c["out"])), "wlc \(input.widthPx)x\(input.heightPx)")
            count += 1
        }
        for c in ref.json["cropped"] as! [[String: Any]] {
            let input = images[c["in"] as! Int]
            #expect(same(input.cropped(to: rect(c["rect"])), ref.image(c["out"])), "crop \(c["rect"]!)")
            count += 1
        }
        for c in ref.json["resampled"] as! [[String: Any]] {
            let input = images[c["in"] as! Int]
            #expect(same(input.resampled(by: Double(bitPattern: UInt64(c["scaleBits"] as! String)!)), ref.image(c["out"])), "resample \(c["scale"]!)")
            count += 1
        }
        for c in ref.json["rows"] as! [[String: Any]] {
            let input = images[c["in"] as! Int]
            #expect(same(input.rows(c["a"] as! Int, c["b"] as! Int), ref.image(c["out"])), "rows \(c["a"]!) \(c["b"]!)")
            count += 1
        }
        for c in ref.json["makeGrayImage"] as! [[String: Any]] {
            let plane = ref.bytes(c["plane"])
            let made = plane.withUnsafeBytes { p in
                SD.makeGrayImage(luma: p.bindMemory(to: UInt8.self).baseAddress!, rowBytes: c["rowBytes"] as! Int, rect: rect(c["rect"]))
            }
            #expect(same(made, ref.image(c["out"])))
            count += 1
        }
        for c in ref.json["candidateRows"] as! [[String: Any]] {
            let rows = SD.candidateRows((c["rects"] as! [Any]).map(rect), in: images[c["in"] as! Int])
            #expect(rows.0 == c["lo"] as! Int && rows.1 == c["hi"] as! Int)
            count += 1
        }
        for c in ref.json["readingBands"] as! [[String: Any]] {
            let grid = SD.TileGrid(widthPx: c["w"] as! Int, heightPx: c["h"] as! Int, tilesX: 0, tilesY: c["tilesY"] as! Int)
            let bands = SD.readingBands(dueRows: c["due"] as! [Bool], grid: grid)
            let want = (c["out"] as! [Any]).map(rect)
            #expect(bands.count == want.count && zip(bands, want).allSatisfy { sameRect($0, $1) })
            count += 1
        }
        print("image/rows cases:", count)
    }

    @Test func stringFunctionsMatchReference() throws {
        let ref = try #require(pure)
        var count = 0
        for c in ref.json["strings"] as! [[String: Any]] {
            let s = c["s"] as! String
            #expect(SD.isSensitiveCandidate(s) == c["candidate"] as! Bool, "candidate \(s.debugDescription)")
            #expect(SD.foldedKey(s) == c["foldedKey"] as! String, "key \(s.debugDescription)")
            for w in c["wordRange"] as! [[Int]] {
                let lo = s.index(s.startIndex, offsetBy: w[0]), hi = s.index(s.startIndex, offsetBy: w[1])
                let r = SD.wordRange(around: lo..<hi, in: s)
                #expect(s.distance(from: s.startIndex, to: r.lowerBound) == w[2] && s.distance(from: s.startIndex, to: r.upperBound) == w[3], "word \(s.debugDescription) \(w)")
            }
            let spans = (c["spans"] as! [[Any]]).map { TextSpan(kind: $0[0] as! String, priority: $0[1] as! Int, range: NSRange(location: $0[2] as! Int, length: $0[3] as! Int)) }
            let got = SD.patternMatches(spans, in: s).map { [$0.kind, $0.priority, s.utf16.distance(from: s.startIndex, to: $0.range.lowerBound), s.utf16.distance(from: s.startIndex, to: $0.range.upperBound)] as [AnyHashable] }
            let want = (c["matches"] as! [[Any]]).map { $0.map { $0 as! AnyHashable } }
            #expect(got == want, "matches \(s.debugDescription)")
            count += 1
        }
        print("string cases:", count)
    }

    @Test func phraseLayerMatchesReference() throws {
        let ref = try #require(pure)
        for c in ref.json["phraseLayer"] as! [[String: Any]] {
            let layer = SD.PhraseLayer(phrase: c["phrase"] as! String)
            #expect(layer.phrase == c["outPhrase"] as! String)
            #expect(layer.id == c["id"] as! String, "id \(layer.phrase)")
            #expect(layer.rule.kind == c["kind"] as! String && layer.rule.priority == c["priority"] as! Int)
            #expect(layer.rule.regex.pattern == c["pattern"] as! String, "pattern \(layer.phrase)")
            #expect(layer.rule.regex.options.rawValue == c["options"] as! UInt)
            #expect(layer.candidateKeys == c["candidateKeys"] as! [String], "keys \(layer.phrase)")
        }
        #expect(SD.PhraseLayer(phrase: "Natan").id == "phrase-cadc0e261adbc0035811")
    }

    @Test func tileLooksMatchReference() throws {
        let ref = try #require(pure)
        var count = 0
        for c in ref.json["looks"] as! [[String: Any]] {
            let grid = SD.TileGrid(widthPx: c["w"] as! Int, heightPx: c["h"] as! Int, tilesX: c["tx"] as! Int, tilesY: c["ty"] as! Int)
            #expect(grid.tiles(in: rect(c["rect"])) == c["tiles"] as! [Int])
            let obs = SD.Observation(timeMs: 0, region: .zero, faceRegion: .zero, lines: [], findings: [], firstTile: c["first"] as! Int,
                                     tileSignatures: (c["sig"] as! [Int]).map { UInt8($0) })
            let got = obs.looks(of: rect(c["rect"]), in: grid)?.map { Array($0) }
            let want = (c["looks"] as? [[Int]])?.map { $0.map { UInt8($0) } }
            #expect(got == want)
            count += 1
        }
        print("looks cases:", count)
    }
}

private let frames = Reference(SDTestData.path("B-oracle/out/frames"))

private func linesOf(_ any: Any?) -> [SD.RecognizedLine] {
    (any as! [[String: Any]]).map { SD.RecognizedLine(text: $0["text"] as! String, key: $0["key"] as! String, rect: rect($0["rect"])) }
}

private func findingsOf(_ any: Any?) -> [SD.Finding] {
    (any as! [[String: Any]]).map { SD.Finding(kind: $0["kind"] as! String, text: $0["text"] as! String, key: $0["key"] as! String, rect: rect($0["rect"])) }
}

private func sameLines(_ a: [SD.RecognizedLine], _ b: [SD.RecognizedLine]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.text == $1.text && $0.key == $1.key && sameRect($0.rect, $1.rect) }
}

private func sameFindings(_ a: [SD.Finding], _ b: [SD.Finding]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.kind == $1.kind && $0.text == $1.text && $0.key == $1.key && sameRect($0.rect, $1.rect) }
}

@Suite(.serialized, .enabled(if: SDTestData.hasReference && SDTestData.runsLongTests)) struct TextReadingFrameTests {
    @Test func snapToInkMatchesReference() throws {
        let ref = try #require(frames)
        var count = 0
        for c in ref.json["frames"] as! [[String: Any]] {
            let image = ref.image(c["image"])!
            let enhanced = image.withLocalContrast(isDimmedOnly: true)
            for s in c["snaps"] as! [[String: Any]] {
                let got = SD.snapToInk(rect(s["rect"]), lineRect: rect(s["line"]), in: (s["enhanced"] as! Bool) ? enhanced : image, canGrow: s["grow"] as! Bool)
                #expect(sameRect(got, rect(s["out"])), "snap \(s)")
                count += 1
            }
        }
        print("snap cases:", count)
    }

    @Test func readTextAndPhrasesMatchReference() throws {
        let ref = try #require(frames)
        var reads = 0, findings = 0, phraseFindings = 0
        for c in ref.json["frames"] as! [[String: Any]] {
            let image = ref.image(c["image"])!
            let read = SD.readText(image)
            let wantLines = linesOf(c["lines"]), wantFindings = findingsOf(c["findings"])
            #expect(sameLines(read.lines, wantLines), "lines at \(c["timeMs"]!) \(read.lines.count) vs \(wantLines.count)")
            #expect(sameFindings(read.findings, wantFindings), "findings at \(c["timeMs"]!): \(read.findings.map(\.text)) vs \(wantFindings.map(\.text))")
            reads += 1
            findings += wantFindings.count
            for (phrase, want) in c["phraseFindings"] as! [String: Any] {
                let layer = SD.PhraseLayer(phrase: phrase)
                let got = SD.readPhrase(image, lines: read.lines, phrase: layer)
                #expect(sameFindings(got, findingsOf(want)), "phrase \(phrase) at \(c["timeMs"]!)")
                phraseFindings += got.count
                let stored = SD.readPhrase(image, lines: wantLines, phrase: layer)
                #expect(sameFindings(stored, findingsOf((c["phraseFindingsStored"] as! [String: Any])[phrase])), "phrase(stored) \(phrase)")
            }
        }
        print("reads:", reads, "findings:", findings, "phrase findings:", phraseFindings)
    }
}
