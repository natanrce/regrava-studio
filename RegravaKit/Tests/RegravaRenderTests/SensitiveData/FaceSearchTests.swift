import CoreGraphics
import Foundation
import Testing
@testable import RegravaRender

private func cascadePath() -> String {
    Bundle.module.path(forResource: "facefinder", ofType: "cascade", inDirectory: "SensitiveData")
        ?? (#filePath as NSString).deletingLastPathComponent + "/../../Sources/SDPort/Resources/SensitiveData/facefinder.cascade"
}

private func grayImage(width: Int, height: Int, origin: CGPoint = .zero, _ pixel: (Int, Int) -> UInt8) -> SD.GrayImage {
    var bytes = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { bytes[y * width + x] = pixel(x, y) } }
    let data = Data(bytes)
    let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                     bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                     intent: .defaultIntent)!
    return SD.GrayImage(bytes: data, widthPx: width, heightPx: height, originPx: origin, cgImage: cg)
}

@Suite struct FaceSearchTests {
    @Test func cascadeLoadsWithTheDetectorsLayout() throws {
        let path = cascadePath()
        let cascade = try SD.loadPicoCascade(path)
        let reference = try #require(PicoCascade(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(cascade.depth == reference.depth && cascade.trees == reference.trees && cascade.leaves == 1 << cascade.depth)
        #expect(cascade.codes == reference.codes)
        #expect(cascade.predictions == reference.predictions && cascade.thresholds == reference.thresholds)
    }

    @Test func cascadeErrors() throws {
        let dir = NSTemporaryDirectory()
        let missing = dir + "no-such-cascade-\(UUID())"
        #expect(throws: SD.SensitiveDataScanError.self) { try SD.loadPicoCascade(missing) }
        do { _ = try SD.loadPicoCascade(missing) } catch let e as SD.SensitiveDataScanError { #expect(e.message == "Cannot read the face cascade at " + missing) }
        let notPico = dir + "bad-\(UUID())"
        try Data([0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1, 0, 0, 0]).write(to: URL(fileURLWithPath: notPico))
        do { _ = try SD.loadPicoCascade(notPico) } catch let e as SD.SensitiveDataScanError { #expect(e.message == "Not a pico cascade: " + notPico) }
        let trailing = dir + "trailing-\(UUID())"
        try (Data(contentsOf: URL(fileURLWithPath: cascadePath())) + Data([0])).write(to: URL(fileURLWithPath: trailing))
        do { _ = try SD.loadPicoCascade(trailing) } catch let e as SD.SensitiveDataScanError { #expect(e.message == "Not a pico cascade (trailing bytes): " + trailing) }
    }

    @Test func flatImageHasNoFacesAndNoPhotos() throws {
        let cascade = try SD.loadPicoCascade(cascadePath())
        let flat = [UInt8](repeating: 128, count: 200 * 150)
        let faces = flat.withUnsafeBufferPointer { SD.scanForFaces(cascade, pixels: $0.baseAddress!, rowBytes: 200, widthPx: 200, heightPx: 150, minSizePx: 0) }
        #expect(faces.isEmpty)
        #expect(SD.photoRegions(in: grayImage(width: 200, height: 150) { _, _ in 128 }).isEmpty)
    }

    @Test func photoCellsGroupIntoGrownRects() {
        // A 64×64 noisy block at (64, 32) inside a flat 256×160 image placed at (10, 20).
        var seed: UInt64 = 7
        let image = grayImage(width: 256, height: 160, origin: CGPoint(x: 10, y: 20)) { x, y in
            guard (64..<128).contains(x), (32..<96).contains(y) else { return 200 }
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        #expect(SD.photoRegions(in: image) == [CGRect(x: 10 + 32, y: 20 + 0, width: 128, height: 128)])
    }

    @Test func areaKeyAndLooks() {
        #expect(SD.FaceSearchCache.areaKey(CGRect(x: 10.9, y: -3.5, width: 100.2, height: 7)) == "10,-3,100,7")
        // The stored origin, the standardized size.
        #expect(SD.FaceSearchCache.areaKey(CGRect(x: 10, y: 20, width: -30, height: 40)) == "10,20,30,40")
        let cache = SD.FaceSearchCache()
        let look: [UInt8] = (0..<16).map { UInt8($0 * 10) }
        let brighter = look.map { $0 + 30 }
        #expect(cache.isSameLook([look], [brighter[...]]))
        var changed = look
        changed[3] += 22  // 16·22 − 22 = 330 > 16·20 (21 would give 315: still the same look)
        #expect(!cache.isSameLook([look], [changed[...]]))
        #expect(!cache.isSameLook([look], []))
    }

    @Test func findingsAreGrownSquaresWithoutOverlaps() {
        let image = grayImage(width: 4, height: 4) { _, _ in 0 }
        let area = SD.FaceSearchArea(region: .zero, original: image, crop: image, image: image, looks: nil, lookKey: 0)
        let a = SD.FaceAreaSearch(area, isQueued: false), b = SD.FaceAreaSearch(area, isQueued: false)
        a.faces = [CGRect(x: 0, y: 0, width: 20, height: 10)]
        b.faces = [CGRect(x: 1, y: 0, width: 20, height: 10), CGRect(x: 100, y: 100, width: 8, height: 8)]
        let findings = SD.faceFindings([a, b])
        #expect(findings.map(\.rect) == [CGRect(x: -2.5, y: -7.5, width: 25, height: 25), CGRect(x: 99, y: 99, width: 10, height: 10)])
        #expect(findings.allSatisfy { $0.kind == "face" && $0.text == "face" && $0.key == "face" })
    }
}
