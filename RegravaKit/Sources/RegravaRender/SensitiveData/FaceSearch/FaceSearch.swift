import CoreGraphics
import Foundation
import Vision

// Finding faces in a read: Vision face rectangles, the pico cascade (load + scan), the
// "photo" cells of a read, the per-area search (pico proposals confirmed by Vision) and the cache
// that reuses searches of areas that look the same.

extension SD {
    // MARK: Pico cascade

    /// A pico face cascade: `trees` decision trees of `depth` pixel comparisons each.
    /// The field names; layout (Int, Int, Int, [Int8], [Float], [Float]).
    struct PicoCascade {
        let depth: Int
        let trees: Int
        /// `1 << depth`.
        let leaves: Int
        /// Per tree `leaves` nodes of 4 signed offsets (row, col, row, col); node 0 is unused (zero).
        let codes: [Int8]
        /// Per tree `leaves` leaf predictions.
        let predictions: [Float]
        /// Per tree its rejection threshold.
        let thresholds: [Float]
    }

    /// The face cascade of the running scan: set to `try options.faceCascadePath.map(loadPicoCascade)`
    /// when a scan starts; without it no area is searched.
    nonisolated(unsafe) static var faceCascade: PicoCascade?

    /// Reads a pico cascade file: 8 header bytes, depth (1...8), tree count, then per tree its node
    /// codes, leaf predictions and threshold (little endian), with nothing left over.
    static func loadPicoCascade(_ path: String) throws -> PicoCascade {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SensitiveDataScanError(message: "Cannot read the face cascade at " + path)
        }
        let bytes = [UInt8](data)
        var offset = 8
        /// 4 little-endian bytes at `offset`, then `offset += 4`.
        func int32() -> Int32 {
            let b0 = bytes[offset], b1 = bytes[offset + 1], b2 = bytes[offset + 2], b3 = bytes[offset + 3]
            offset += 4
            return Int32(bitPattern: UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24)
        }
        let depth = int32()
        let trees = int32()
        guard (1...8).contains(depth), trees > 0 else {
            throw SensitiveDataScanError(message: "Not a pico cascade: " + path)
        }
        let depthInt = Int(depth), treeCount = Int(trees)
        let leaves = 1 << depthInt
        var codes = [Int8](repeating: 0, count: (treeCount << depthInt) * 4)
        var predictions = [Float](repeating: 0, count: treeCount << depthInt)
        var thresholds = [Float](repeating: 0, count: treeCount)
        for tree in 0..<treeCount {
            for node in 1..<leaves {
                let at = (tree * leaves + node) * 4
                codes[at] = Int8(bitPattern: bytes[offset])
                codes[at + 1] = Int8(bitPattern: bytes[offset + 1])
                codes[at + 2] = Int8(bitPattern: bytes[offset + 2])
                codes[at + 3] = Int8(bitPattern: bytes[offset + 3])
                offset += 4
            }
            for leaf in 0..<leaves {
                let b0 = bytes[offset], b1 = bytes[offset + 1], b2 = bytes[offset + 2], b3 = bytes[offset + 3]
                offset += 4
                predictions[tree * leaves + leaf] = Float(bitPattern: UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24)
            }
            let b0 = bytes[offset], b1 = bytes[offset + 1], b2 = bytes[offset + 2], b3 = bytes[offset + 3]
            offset += 4
            thresholds[tree] = Float(bitPattern: UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24)
        }
        guard offset == bytes.count else {
            throw SensitiveDataScanError(message: "Not a pico cascade (trailing bytes): " + path)
        }
        return PicoCascade(depth: depthInt, trees: treeCount, leaves: leaves, codes: codes, predictions: predictions, thresholds: thresholds)
    }

    /// The pico cascade
    /// over square windows of integer sizes from `max(minSizePx, 10)` to `min(widthPx, heightPx)`
    /// (each next size `max(size * 11 / 10, size + 1)`), stepping `size / 10` (1 below 20), then the
    /// windows clustered strongest first (IoU > 0.2, averaged centre and size, summed score).
    static func scanForFaces(_ cascade: PicoCascade, pixels: UnsafePointer<UInt8>, rowBytes: Int, widthPx: Int, heightPx: Int,
                             minSizePx: Int) -> [(row: Double, col: Double, size: Double, score: Float)] {
        var size = minSizePx < 11 ? 10 : minSizePx
        let maxSize = min(widthPx, heightPx)
        var raw: [(row: Int, col: Int, size: Int, score: Float)] = []
        while size <= maxSize {
            let step = size < 20 ? 1 : size / 10
            let half = size / 2 + 1
            for row in stride(from: half, through: heightPx - half, by: step) {
                for col in stride(from: half, through: widthPx - half, by: step) {
                    let r = row * 256, c = col * 256
                    var score: Float = 0
                    var rejected = false
                    for tree in 0..<cascade.trees {
                        let base = tree * cascade.leaves
                        var index = 1
                        for _ in 0..<cascade.depth {
                            let at = (base + index) * 4
                            let r1 = (r + Int(cascade.codes[at]) * size) >> 8
                            let c1 = (c + Int(cascade.codes[at + 1]) * size) >> 8
                            let r2 = (r + Int(cascade.codes[at + 2]) * size) >> 8
                            let c2 = (c + Int(cascade.codes[at + 3]) * size) >> 8
                            index = index * 2 + (pixels[r1 * rowBytes + c1] <= pixels[r2 * rowBytes + c2] ? 1 : 0)
                        }
                        score += cascade.predictions[base + index - cascade.leaves]
                        if score <= cascade.thresholds[tree] {
                            rejected = true
                            break
                        }
                    }
                    if !rejected { score -= cascade.thresholds[cascade.trees - 1] } else { score = -1 }
                    if score > 0 { raw.append((row: row, col: col, size: size, score: score)) }
                }
            }
            size = max(size * 11 / 10, size + 1)
        }
        // Strongest first.
        raw.sort { $0.score > $1.score }
        var isAssigned = [Bool](repeating: false, count: raw.count)
        var faces: [(row: Double, col: Double, size: Double, score: Float)] = []
        for i in raw.indices where !isAssigned[i] {
            var count = 0
            var row = 0.0, col = 0.0, sumSize = 0.0
            var score: Float = 0
            for j in i..<raw.count where !isAssigned[j] {
                let a = raw[i], b = raw[j]
                let ha = Double(a.size) / 2, hb = Double(b.size) / 2
                let overRows = max(min(Double(a.row) + ha, Double(b.row) + hb) - max(Double(a.row) - ha, Double(b.row) - hb), 0)
                let overCols = max(min(Double(a.col) + ha, Double(b.col) + hb) - max(Double(a.col) - ha, Double(b.col) - hb), 0)
                let overlap = overRows * overCols
                if overlap / (Double(a.size * a.size + b.size * b.size) - overlap) > 0.2 {
                    isAssigned[j] = true
                    count += 1
                    row += Double(b.row)
                    col += Double(b.col)
                    sumSize += Double(b.size)
                    score += b.score
                }
            }
            let n = Double(count)
            faces.append((row: row / n, col: col / n, size: sumSize / n, score: score))
        }
        return faces
    }

    /// The bytes of `data` as a pointer (a zeroed byte for empty data; never read as the size is 0).
    private static func withPixels<R>(of data: Data, _ body: (UnsafePointer<UInt8>) -> R) -> R {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress { return body(base) }
            var zero: UInt8 = 0
            return withUnsafePointer(to: &zero) { body($0) }
        }
    }

    // MARK: Vision

    /// A default `VNDetectFaceRectanglesRequest` on the image's
    /// CGImage; boxes mapped to video pixels (top-left origin). Failures give no faces.
    static func visionFaces(in image: GrayImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { faceSearchStats.add(visionCalls: 1, visionSeconds: CFAbsoluteTimeGetCurrent() - startedAt, picoSeconds: 0) }
        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let width = Double(image.widthPx), height = Double(image.heightPx)
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            return CGRect(x: image.originPx.x + box.minX * width, y: image.originPx.y + (1 - box.maxY) * height,
                          width: box.width * width, height: box.height * height)
        }
    }

    // MARK: Photo regions

    /// 32-px cells whose 2-px-subsampled histogram (32 bins of
    /// `value >> 3`) has more than 6 bins above 5 count as photo; 4-connected groups of them give one
    /// rect each, grown by one cell around, in video pixels, clipped to the image.
    static func photoRegions(in image: GrayImage) -> [CGRect] {
        let widthPx = image.widthPx, heightPx = image.heightPx
        guard widthPx >= 32, heightPx >= 32 else { return [] }
        let cellsX = widthPx / 32, cellsY = heightPx / 32
        var isPhoto = [Bool](repeating: false, count: cellsX * cellsY)
        image.bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var histogram = [Int](repeating: 0, count: 32)
            for cellY in 0..<cellsY {
                for cellX in 0..<cellsX {
                    for bin in 0..<32 { histogram[bin] = 0 }
                    for y in stride(from: cellY * 32, to: (cellY + 1) * 32, by: 2) {
                        for x in stride(from: cellX * 32, to: (cellX + 1) * 32, by: 2) {
                            histogram[Int(bytes[y * widthPx + x] >> 3)] += 1
                        }
                    }
                    isPhoto[cellY * cellsX + cellX] = histogram.filter { $0 > 5 }.count > 6
                }
            }
        }
        var isVisited = [Bool](repeating: false, count: isPhoto.count)
        var regions: [CGRect] = []
        for start in isPhoto.indices where isPhoto[start] && !isVisited[start] {
            var stack = [start]
            isVisited[start] = true
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            while let cell = stack.popLast() {
                let y = cell / cellsX, x = cell % cellsX
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < cellsX && ny >= 0 && ny < cellsY {
                    let neighbour = ny * cellsX + nx
                    if isPhoto[neighbour] && !isVisited[neighbour] {
                        isVisited[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }
            let cells = CGRect(x: Double((minX - 1) * 32), y: Double((minY - 1) * 32),
                               width: Double((maxX - minX + 3) * 32), height: Double((maxY - minY + 3) * 32))
            regions.append(cells.offsetBy(dx: image.originPx.x, dy: image.originPx.y)
                .intersection(CGRect(x: image.originPx.x, y: image.originPx.y, width: Double(widthPx), height: Double(heightPx))))
        }
        return regions
    }

    // MARK: Stats

    /// Time and counts of the face search, for the scan stats.
    final class FaceSearchStats {
        let lock = NSLock()
        var visionCalls = 0
        var visionSeconds = 0.0
        var picoSeconds = 0.0
        var searchedRegions = 0
        var reusedRegions = 0

        /// Under the lock, both second counters are always added to (`+ 0.0` when unused), the Int
        /// counters only when non-zero.
        func add(visionCalls: Int = 0, visionSeconds: Double, picoSeconds: Double, searchedRegions: Int = 0, reusedRegions: Int = 0) {
            lock.lock()
            if visionCalls != 0 { self.visionCalls += visionCalls }
            self.visionSeconds += visionSeconds
            self.picoSeconds += picoSeconds
            if searchedRegions != 0 { self.searchedRegions += searchedRegions }
            if reusedRegions != 0 { self.reusedRegions += reusedRegions }
            lock.unlock()
        }
    }

    /// The face search stats of the process.
    static let faceSearchStats = FaceSearchStats()

    // MARK: Searching an area

    /// The search of one photo area; queued as an operation when `isQueued`.
    final class FaceAreaSearch {
        var area: FaceSearchArea?
        var faces: [CGRect] = []
        var operation: Operation?

        init(_ area: FaceSearchArea, isQueued: Bool) {
            self.area = area
            if isQueued {
                operation = BlockOperation { [weak self] in
                    autoreleasepool {
                        self?.search()
                    }
                }
            }
        }

        /// Searches the area once (the area is dropped afterwards).
        func search() {
            guard let area, let cascade = SD.faceCascade else { return }
            faces = SD.searchFaces(in: area, cascade: cascade)
            self.area = nil
        }
    }

    /// Areas under 256 px on their short side: Vision on the
    /// crop when pico proposes a face in it (at 3×). Larger: Vision on the crop, then up to 24 pico
    /// proposals (strongest first) not inside a face already found: Vision on a 3×-size square around
    /// each, in the area's contrast image, keeping faces whose centre is within 0.6 × the proposal size.
    static func searchFaces(in area: FaceSearchArea, cascade: PicoCascade) -> [CGRect] {
        let crop = area.crop
        let side = min(crop.widthPx, crop.heightPx)
        if side < 256 {
            return isFaceProposed(in: crop, cascade: cascade) ? visionFaces(in: crop) : []
        }
        var faces = visionFaces(in: crop)
        let startedAt = CFAbsoluteTimeGetCurrent()
        var proposals = withPixels(of: crop.bytes) { pixels in
            scanForFaces(cascade, pixels: pixels, rowBytes: crop.widthPx, widthPx: crop.widthPx,
                         heightPx: crop.heightPx, minSizePx: side < 480 ? 20 : side / 24)
        }
        faceSearchStats.add(visionSeconds: 0, picoSeconds: CFAbsoluteTimeGetCurrent() - startedAt)
        // Strongest first.
        proposals.sort { $0.score > $1.score }
        for proposal in proposals.prefix(24) {
            let x = crop.originPx.x + proposal.col, y = crop.originPx.y + proposal.row
            if faces.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { continue }
            let span = proposal.size * 3
            guard let around = area.image.cropped(to: CGRect(x: x - span * 0.5, y: y - span * 0.5, width: span, height: span)) else { continue }
            faces.append(contentsOf: visionFaces(in: around).filter { hypot($0.midX - x, $0.midY - y) < proposal.size * 0.6 })
        }
        return faces
    }

    /// Pico (min size 36) on the image drawn at 3× with
    /// high interpolation into a DeviceGray bitmap.
    static func isFaceProposed(in image: GrayImage, cascade: PicoCascade) -> Bool {
        let widthPx = image.widthPx * 3, heightPx = image.heightPx * 3
        var pixels = Data(count: widthPx * heightPx)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            if let context = CGContext(data: raw.baseAddress, width: widthPx, height: heightPx, bitsPerComponent: 8, bytesPerRow: widthPx,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) {
                context.interpolationQuality = .high
                context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: Double(widthPx), height: Double(heightPx)))
            }
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { faceSearchStats.add(visionSeconds: 0, picoSeconds: CFAbsoluteTimeGetCurrent() - startedAt) }
        return !withPixels(of: pixels) { pixels in
            scanForFaces(cascade, pixels: pixels, rowBytes: widthPx, widthPx: widthPx, heightPx: heightPx, minSizePx: 36)
        }.isEmpty
    }

    // MARK: Cache

    /// Searches already made in a chunk, by area look and by area rect.
    final class FaceSearchCache {
        let lock = NSLock()
        var searchesByLook: [Int: FaceAreaSearch] = [:]
        var byArea: [String: (looks: [[UInt8]], search: FaceAreaSearch)] = [:]

        /// Per area, the search of the same
        /// area rect when it still looks the same, else the search of an area with the same `lookKey`,
        /// else a new one.
        func plan(_ areas: [FaceSearchArea], isQueued: Bool) -> (searches: [FaceAreaSearch], newSearches: [FaceAreaSearch]) {
            lock.lock()
            var newSearches: [FaceAreaSearch] = []
            let searches = areas.map { area -> FaceAreaSearch in
                let key = Self.areaKey(area.region)
                if let looks = area.looks, let entry = byArea[key], isSameLook(entry.looks, looks) {
                    SD.faceSearchStats.add(visionSeconds: 0, picoSeconds: 0, reusedRegions: 1)
                    return entry.search
                }
                let search: FaceAreaSearch
                if let existing = searchesByLook[area.lookKey] {
                    SD.faceSearchStats.add(visionSeconds: 0, picoSeconds: 0, reusedRegions: 1)
                    search = existing
                } else {
                    SD.faceSearchStats.add(visionSeconds: 0, picoSeconds: 0, searchedRegions: 1)
                    search = FaceAreaSearch(area, isQueued: isQueued)
                    searchesByLook[area.lookKey] = search
                    newSearches.append(search)
                }
                if let looks = area.looks {
                    byArea[key] = (looks: looks.map { Array($0) }, search: search)
                }
                return search
            }
            lock.unlock()
            return (searches, newSearches)
        }

        /// The area rect, truncated to whole pixels: its origin as stored, its standardized size.
        static func areaKey(_ rect: CGRect) -> String {
            "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
        }

        /// Every 16-block look, mean removed (in sixteenths), within
        /// `options.changeThreshold` of the stored one.
        func isSameLook(_ stored: [[UInt8]], _ looks: [ArraySlice<UInt8>]) -> Bool {
            guard stored.count == looks.count else { return false }
            let threshold = SD.options.changeThreshold * 16
            for (old, new) in zip(stored, looks) {
                let oldSum = (0..<16).reduce(0) { $0 + Int(old[$1]) }
                let newSum = (0..<16).reduce(0) { $0 + Int(new[new.startIndex + $1]) }
                for block in 0..<16 {
                    let difference = (Int(old[block]) * 16 - oldSum) - (Int(new[new.startIndex + block]) * 16 - newSum)
                    if difference > threshold || difference < -threshold { return false }
                }
            }
            return true
        }

        /// The image's origin and size, and the sums of 2-px-subsampled 8×8
        /// blocks, hashed.
        static func key(of image: GrayImage) -> Int {
            var hasher = Hasher()
            hasher.combine(Int(image.originPx.x))
            hasher.combine(Int(image.originPx.y))
            hasher.combine(image.widthPx)
            hasher.combine(image.heightPx)
            let widthPx = image.widthPx, heightPx = image.heightPx
            image.bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in stride(from: 0, to: heightPx - 7, by: 8) {
                    for x in stride(from: 0, to: widthPx - 7, by: 8) {
                        var sum = 0
                        for yy in stride(from: y, to: y + 8, by: 2) {
                            for xx in stride(from: x, to: x + 8, by: 2) {
                                sum += Int(bytes[yy * widthPx + xx])
                            }
                        }
                        hasher.combine(sum)
                    }
                }
            }
            return hasher.finalize()
        }
    }

    // MARK: Faces of a read

    /// One area per photo region of the read
    /// (found on the dimmed-only local-contrast image), with the region's plain and contrast crops.
    static func prepareFaceSearch(in image: GrayImage, looksOfArea: ((CGRect) -> [ArraySlice<UInt8>]?)?) -> [FaceSearchArea] {
        let regions = photoRegions(in: image.withLocalContrast(isDimmedOnly: true))
        if regions.isEmpty { return [] }
        let contrast = image.withLocalContrast(isDimmedOnly: false)
        var areas: [FaceSearchArea] = []
        for region in regions {
            guard let original = image.cropped(to: region) else { continue }
            guard let crop = contrast.cropped(to: region) else { continue }
            let looks = looksOfArea?(region)
            areas.append(FaceSearchArea(region: region, original: original, crop: crop, image: contrast, looks: looks,
                                        lookKey: FaceSearchCache.key(of: original)))
        }
        return areas
    }

    /// The faces of all searches, dropping one overlapping a kept face
    /// by IoU > 0.3, as squares 1.25 × their long side around their centre.
    static func faceFindings(_ searches: [FaceAreaSearch]) -> [Finding] {
        let faces = searches.flatMap { $0.faces }
        var kept: [CGRect] = []
        for face in faces where !kept.contains(where: { intersectionOverUnion($0, face) > 0.3 }) {
            kept.append(face)
        }
        return kept.map { face in
            let side = max(face.width, face.height) * 1.25
            return Finding(kind: "face", text: "face", key: "face",
                           rect: CGRect(x: face.midX - side * 0.5, y: face.midY - side * 0.5, width: side, height: side))
        }
    }

    /// The faces of a read, searched synchronously.
    static func findFaces(in image: GrayImage, cache: FaceSearchCache, looksOfArea: ((CGRect) -> [ArraySlice<UInt8>]?)?) -> [Finding] {
        let areas = prepareFaceSearch(in: image, looksOfArea: looksOfArea)
        let (searches, newSearches) = cache.plan(areas, isQueued: false)
        for search in newSearches {
            search.search()
        }
        return faceFindings(searches)
    }
}
