import Foundation

/// The pico face detector, run with `facefinder.cascade` (Markuš et al., the `pico.js`
/// cascade format): pixel-comparison decision trees over a grayscale image, scanned at
/// growing scales, then clustered by overlap.
public struct PicoCascade: Sendable {
    let depth: Int
    let trees: Int
    /// Per tree, 4 signed bytes per node (row, col, row, col offsets), node 0 unused.
    let codes: [Int8]
    let predictions: [Float]
    let thresholds: [Float]

    public static let bundled: PicoCascade? = Bundle.module.url(forResource: "facefinder", withExtension: "cascade", subdirectory: "SensitiveData")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap(PicoCascade.init(data:))

    /// `unpack_cascade`: 8 header bytes, depth, tree count, then each tree's codes, leaf
    /// predictions and threshold (little endian).
    public init?(data: Data) {
        let bytes = [UInt8](data)
        func int32(_ at: Int) -> Int { Int(Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)) }
        func float32(_ at: Int) -> Float { Float(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24) }
        guard bytes.count > 16 else { return nil }
        var p = 8
        depth = int32(p); p += 4
        trees = int32(p); p += 4
        let leaves = 1 << depth
        guard depth > 0, depth < 16, trees > 0 else { return nil }
        var codes: [Int8] = []
        var predictions: [Float] = []
        var thresholds: [Float] = []
        codes.reserveCapacity(trees * 4 * leaves)
        for _ in 0..<trees {
            let codeBytes = 4 * leaves - 4
            guard p + codeBytes + 4 * leaves + 4 <= bytes.count else { return nil }
            codes += [0, 0, 0, 0]
            codes += bytes[p..<(p + codeBytes)].map { Int8(bitPattern: $0) }
            p += codeBytes
            for _ in 0..<leaves {
                predictions.append(float32(p))
                p += 4
            }
            thresholds.append(float32(p))
            p += 4
        }
        self.codes = codes
        self.predictions = predictions
        self.thresholds = thresholds
    }

    /// `classify_region`: the score of a window centred at (row, col) of size `scale`, or < 0.
    func classify(row: Int, col: Int, scale: Int, pixels: UnsafePointer<UInt8>, width: Int, height: Int) -> Float {
        let r = row * 256, c = col * 256
        let leaves = 1 << depth
        var root = 0
        var score: Float = 0
        for tree in 0..<trees {
            var index = 1
            for _ in 0..<depth {
                let base = root + 4 * index
                let r1 = (r + Int(codes[base]) * scale) >> 8, c1 = (c + Int(codes[base + 1]) * scale) >> 8
                let r2 = (r + Int(codes[base + 2]) * scale) >> 8, c2 = (c + Int(codes[base + 3]) * scale) >> 8
                guard r1 >= 0, r1 < height, c1 >= 0, c1 < width, r2 >= 0, r2 < height, c2 >= 0, c2 < width else { return -1 }
                index = 2 * index + (pixels[r1 * width + c1] <= pixels[r2 * width + c2] ? 1 : 0)
            }
            score += predictions[leaves * tree + index - leaves]
            if score <= thresholds[tree] { return -1 }
            root += 4 * leaves
        }
        return score - thresholds[trees - 1]
    }

    public struct Detection: Hashable, Sendable {
        /// Centre (x, y) and size in pixels, and the summed score.
        public var x: Double
        public var y: Double
        public var size: Double
        public var score: Double
    }

    public struct Parameters: Sendable {
        public var minSize: Int
        public var maxSize: Int
        public var shiftFactor: Double
        public var scaleFactor: Double
        public var overlapThreshold: Double
        public var minScore: Double

        public init(minSize: Int, maxSize: Int, shiftFactor: Double = 0.1, scaleFactor: Double = 1.1, overlapThreshold: Double = 0.2, minScore: Double = 0) {
            self.minSize = minSize
            self.maxSize = maxSize
            self.shiftFactor = shiftFactor
            self.scaleFactor = scaleFactor
            self.overlapThreshold = overlapThreshold
            self.minScore = minScore
        }
    }

    /// `run_cascade` then `cluster_detections` over a grayscale image (row-major, `width` bytes a row).
    public func detect(gray: [UInt8], width: Int, height: Int, parameters: Parameters) -> [Detection] {
        var raw: [Detection] = []
        gray.withUnsafeBufferPointer { buffer in
            guard let pixels = buffer.baseAddress else { return }
            var scale = Double(parameters.minSize)
            while scale <= Double(parameters.maxSize) {
                let s = Int(scale)
                let step = max(Int(parameters.shiftFactor * scale), 1)
                let offset = s / 2 + 1
                var row = offset
                while row <= height - offset {
                    var col = offset
                    while col <= width - offset {
                        let q = classify(row: row, col: col, scale: s, pixels: pixels, width: width, height: height)
                        if q > 0 { raw.append(Detection(x: Double(col), y: Double(row), size: Double(s), score: Double(q))) }
                        col += step
                    }
                    row += step
                }
                scale *= parameters.scaleFactor
            }
        }
        return Self.cluster(raw, overlap: parameters.overlapThreshold).filter { $0.score > parameters.minScore }
    }

    /// `cluster_detections`: strongest first, windows overlapping it above the threshold averaged.
    static func cluster(_ detections: [Detection], overlap threshold: Double) -> [Detection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var assigned = [Bool](repeating: false, count: sorted.count)
        var clusters: [Detection] = []
        func iou(_ a: Detection, _ b: Detection) -> Double {
            let overW = max(0, min(a.x + a.size / 2, b.x + b.size / 2) - max(a.x - a.size / 2, b.x - b.size / 2))
            let overH = max(0, min(a.y + a.size / 2, b.y + b.size / 2) - max(a.y - a.size / 2, b.y - b.size / 2))
            let inter = overW * overH
            return inter / (a.size * a.size + b.size * b.size - inter)
        }
        for i in sorted.indices where !assigned[i] {
            var n = 0.0, x = 0.0, y = 0.0, s = 0.0, q = 0.0
            for j in sorted.indices where !assigned[j] && iou(sorted[i], sorted[j]) > threshold {
                assigned[j] = true
                n += 1
                x += sorted[j].x
                y += sorted[j].y
                s += sorted[j].size
                q += sorted[j].score
            }
            clusters.append(Detection(x: x / n, y: y / n, size: s / n, score: q))
        }
        return clusters
    }
}
