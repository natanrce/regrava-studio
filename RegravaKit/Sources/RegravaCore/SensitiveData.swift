import Foundation

// Privacy auto-masking: what the scan finds and how a frame's covers are worked out from it.

/// `processing`.
public struct ProcessingConfig: Codable, Hashable, Sendable {
    public var improveRecordingQuality01 = 0.5
    public var autoMaskSensitiveData = false
    /// Padding around text covers; no UI.
    public var sensitiveDataExpandPx = 8.0
    public var sensitiveDataCustomPhrases: [String] = []
    public var autoMaskFaces = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProcessingConfig()
        improveRecordingQuality01 = c.value(.improveRecordingQuality01, default: d.improveRecordingQuality01)
        autoMaskSensitiveData = c.value(.autoMaskSensitiveData, default: d.autoMaskSensitiveData)
        sensitiveDataExpandPx = c.value(.sensitiveDataExpandPx, default: d.sensitiveDataExpandPx)
        sensitiveDataCustomPhrases = c.value(.sensitiveDataCustomPhrases, default: d.sensitiveDataCustomPhrases)
        autoMaskFaces = c.value(.autoMaskFaces, default: d.autoMaskFaces)
    }

    public var isAutoMasking: Bool { autoMaskSensitiveData || autoMaskFaces }

    /// Comma separated, trimmed, whitespace collapsed, empty and case-insensitive
    /// duplicates dropped, order kept.
    public static func parsePhrases(_ text: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let cleaned = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            out.append(cleaned)
        }
        return out
    }
}

public enum SensitiveDataKind: String, Codable, Hashable, Sendable {
    /// `identifier`: labelled IDs, VAT, national numbers, IP and MAC addresses, wallets and the like.
    case email, phone, address, ssn, card, iban, apiKey, secret, privateKey, identifier, custom, face
}

/// Where an item is at a moment, in video pixels, top-left origin, already padded past the text.
public struct SensitiveDataKeyframe: Codable, Hashable, Sendable {
    public var timeMs: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(timeMs: Double, x: Double, y: Double, width: Double, height: Double) {
        self.timeMs = timeMs
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var rect: Rect2 { Rect2(x: x, y: y, width: width, height: height) }
}

/// One found item, covered for `[startMs, endMs)` of recording time.
public struct SensitiveDataDetection: Codable, Hashable, Sendable {
    /// The scan's number for the item (0 in results stored before ids were kept).
    public var id: Int
    public var kind: SensitiveDataKind
    public var text: String
    public var startMs: Double
    public var endMs: Double
    public var isTyped: Bool
    public var keyframes: [SensitiveDataKeyframe]
    /// The recording session whose video was scanned.
    public var sessionIndex: Int
    /// Size of the scanned video, the space of the keyframes (0 in results stored before it was
    /// kept: the recording's video size is used then).
    public var videoWidthPx: Double
    public var videoHeightPx: Double

    public init(id: Int = 0, kind: SensitiveDataKind, text: String, startMs: Double, endMs: Double, isTyped: Bool = false, keyframes: [SensitiveDataKeyframe],
                sessionIndex: Int = 0, videoWidthPx: Double = 0, videoHeightPx: Double = 0) {
        self.id = id
        self.kind = kind
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.isTyped = isTyped
        self.keyframes = keyframes
        self.sessionIndex = sessionIndex
        self.videoWidthPx = videoWidthPx
        self.videoHeightPx = videoHeightPx
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        kind = try c.decode(SensitiveDataKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        startMs = try c.decode(Double.self, forKey: .startMs)
        endMs = try c.decode(Double.self, forKey: .endMs)
        isTyped = try c.decodeIfPresent(Bool.self, forKey: .isTyped) ?? false
        keyframes = try c.decode([SensitiveDataKeyframe].self, forKey: .keyframes)
        sessionIndex = try c.decodeIfPresent(Int.self, forKey: .sessionIndex) ?? 0
        videoWidthPx = try c.decodeIfPresent(Double.self, forKey: .videoWidthPx) ?? 0
        videoHeightPx = try c.decodeIfPresent(Double.self, forKey: .videoHeightPx) ?? 0
    }
}

/// The covers of one frame, as 0…1 rects of the video.
public struct AutoMaskFrame: Hashable, Sendable {
    public var bounds01: [Rect2] = []
    public var faceBounds01: [Rect2] = []
    public var isEmpty: Bool { bounds01.isEmpty && faceBounds01.isEmpty }
    public init(bounds01: [Rect2] = [], faceBounds01: [Rect2] = []) {
        self.bounds01 = bounds01
        self.faceBounds01 = faceBounds01
    }
}

/// Detections in start order, indexed so a frame skips the ones that have already ended.
public struct AutoMaskTimeline: Sendable {
    public let detections: [SensitiveDataDetection]
    /// `latestEnd[i]`: the latest `endMs` among `detections[0...i]`; empty when the detections
    /// are not in start order, so nothing is skipped.
    let latestEnd: [Double]
    /// Whether each detection's keyframes are in time order.
    let keyframesSorted: [Bool]

    /// `detections` should be sorted by `startMs`.
    public init(detections: [SensitiveDataDetection]) {
        self.detections = detections
        let inStartOrder = zip(detections, detections.dropFirst()).allSatisfy { $0.startMs <= $1.startMs }
        var latest: [Double] = []
        if inStartOrder {
            latest.reserveCapacity(detections.count)
            for d in detections { latest.append(Swift.max(latest.last ?? -.infinity, d.endMs)) }
        }
        latestEnd = latest
        keyframesSorted = detections.map { d in zip(d.keyframes, d.keyframes.dropFirst()).allSatisfy { $0.timeMs <= $1.timeMs } }
    }

    public var isEmpty: Bool { detections.isEmpty }

    /// Every detection before this index has ended by `t` (`endMs <= t`).
    func firstUnended(at t: Double) -> Int {
        var lo = 0, hi = latestEnd.count
        while lo < hi { let mid = (lo + hi) / 2; if latestEnd[mid] > t { hi = mid } else { lo = mid + 1 } }
        return lo
    }
}

public enum AutoMasks {
    /// Text and face covers the GPU takes at most.
    public static let maxTextBoxes = 32
    public static let maxFaceBoxes = 16

    /// The detections of session `sessionIndex` covering `sourceMs`, as boxes of the scanned
    /// video (the last covering detection's size; `videoSize` for results stored without one).
    /// Nothing covering: no boxes.
    public static func frame(at sourceMs: Double, timeline: AutoMaskTimeline, config: ProcessingConfig, videoSize: Size2, sessionIndex: Int = 0) -> AutoMaskFrame {
        guard config.isAutoMasking else { return AutoMaskFrame() }
        var text: [Rect2] = []
        var faces: [Rect2] = []
        var scannedSize: Size2?
        let detections = timeline.detections
        for index in timeline.firstUnended(at: sourceMs)..<detections.count {
            let detection = detections[index]
            if detection.startMs > sourceMs { break }
            guard detection.sessionIndex == sessionIndex, detection.endMs > sourceMs else { continue }
            let isFace = detection.kind == .face
            guard isFace ? config.autoMaskFaces : config.autoMaskSensitiveData,
                  var rect = rect(of: detection, at: sourceMs, keyframesSorted: timeline.keyframesSorted[index]) else { continue }
            let size = detection.videoWidthPx > 0 && detection.videoHeightPx > 0
                ? Size2(width: detection.videoWidthPx, height: detection.videoHeightPx) : videoSize
            // Entirely outside the video.
            guard rect.x < size.width, rect.y < size.height, rect.x + rect.width > 0, rect.y + rect.height > 0 else { continue }
            scannedSize = size
            if isFace {
                faces.append(rect)
            } else {
                let pad = config.sensitiveDataExpandPx
                rect = Rect2(x: rect.x - pad, y: rect.y - pad, width: rect.width + 2 * pad, height: rect.height + 2 * pad)
                text.append(rect)
            }
        }
        guard let size = scannedSize, size.width > 0, size.height > 0 else { return AutoMaskFrame() }
        text = merged(text, shouldMerge: textBoxesMerge)
        faces = merged(faces, shouldMerge: faceBoxesMerge)
        func normalized(_ r: Rect2) -> Rect2 {
            Rect2(x: r.x / size.width, y: r.y / size.height, width: r.width / size.width, height: r.height / size.height)
        }
        return AutoMaskFrame(bounds01: capped(text, max: maxTextBoxes).map(normalized), faceBounds01: capped(faces, max: maxFaceBoxes).map(normalized))
    }

    /// `frame(at:timeline:…)` over detections sorted by `startMs`, indexed for this call only.
    public static func frame(at sourceMs: Double, detections: [SensitiveDataDetection], config: ProcessingConfig, videoSize: Size2, sessionIndex: Int = 0) -> AutoMaskFrame {
        frame(at: sourceMs, timeline: AutoMaskTimeline(detections: detections), config: config, videoSize: videoSize, sessionIndex: sessionIndex)
    }

    /// A face holds its last keyframe; text between two keyframes covers both (never interpolated).
    /// Keyframes in time order are found by binary search.
    static func rect(of detection: SensitiveDataDetection, at t: Double, keyframesSorted: Bool = false) -> Rect2? {
        let keys = detection.keyframes
        guard let first = keys.first else { return nil }
        /// First index whose keyframe passes `isAfter`, which is false then true along `keys`.
        func boundary(_ isAfter: (SensitiveDataKeyframe) -> Bool) -> Int {
            var lo = 0, hi = keys.count
            while lo < hi { let mid = (lo + hi) / 2; if isAfter(keys[mid]) { hi = mid } else { lo = mid + 1 } }
            return lo
        }
        if detection.kind == .face {
            guard keyframesSorted else { return (keys.last { $0.timeMs <= t } ?? first).rect }
            let after = boundary { !($0.timeMs <= t) }
            return (after > 0 ? keys[after - 1] : first).rect
        }
        let found = keyframesSorted ? boundary { $0.timeMs >= t } : (keys.firstIndex { $0.timeMs >= t } ?? keys.count)
        guard found < keys.count else { return keys.last?.rect }
        let i = found
        if i == 0 || keys[i].timeMs == t { return keys[i].rect }
        return union(keys[i - 1].rect, keys[i].rect)
    }

    static func union(_ a: Rect2, _ b: Rect2) -> Rect2 {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        return Rect2(x: x0, y: y0, width: max(a.x + a.width, b.x + b.width) - x0, height: max(a.y + a.height, b.y + b.height) - y0)
    }

    /// Overlapping lines, or lines on the same row close together.
    static func textBoxesMerge(_ a: Rect2, _ b: Rect2) -> Bool {
        let vertical = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        let horizontalOverlap = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let minH = min(a.height, b.height)
        if vertical > 0 && horizontalOverlap > 0 { return true }
        let gap = max(a.x, b.x) - min(a.x + a.width, b.x + b.width)
        return vertical >= 0.5 * minH && gap < 0.5 * minH
    }

    /// Faces sharing at least a third of the smaller one.
    static func faceBoxesMerge(_ a: Rect2, _ b: Rect2) -> Bool {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard w > 0, h > 0 else { return false }
        return w * h >= min(a.width * a.height, b.width * b.height) / 3
    }

    /// Pairs are replaced by their union until nothing merges.
    static func merged(_ boxes: [Rect2], shouldMerge: (Rect2, Rect2) -> Bool) -> [Rect2] {
        var boxes = boxes
        var changed = true
        while changed {
            changed = false
            outer: for i in boxes.indices {
                for j in boxes.indices where j > i && shouldMerge(boxes[i], boxes[j]) {
                    boxes[i] = union(boxes[i], boxes[j])
                    boxes.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return boxes
    }

    /// Too many boxes: the pair whose union adds the least area merges first.
    static func capped(_ boxes: [Rect2], max: Int) -> [Rect2] {
        var boxes = boxes
        while boxes.count > max {
            var best = (0, 1, Double.infinity)
            for i in boxes.indices {
                for j in boxes.indices where j > i {
                    let u = union(boxes[i], boxes[j])
                    let extra = u.width * u.height - boxes[i].width * boxes[i].height - boxes[j].width * boxes[j].height
                    if extra < best.2 { best = (i, j, extra) }
                }
            }
            boxes[best.0] = union(boxes[best.0], boxes[best.1])
            boxes.remove(at: best.1)
        }
        return boxes
    }
}

/// An export can draw frames while the scan still runs, from the partial results final past the
/// frame. Afterwards the complete result is checked against each partial result it drew from.
public enum SensitiveDataExportCheck {
    /// A frame is drawn once its partial result is final this far past it.
    public static let readyLeadMs = 1000.0
    /// Margin around the drawn range compared with the complete result.
    public static let compareMarginMs = 1000.0

    /// Whether a frame at `sourceMs` can be drawn from a partial result final up to `finalUpToMs`.
    public static func isReady(sourceMs: Double, finalUpToMs: Double) -> Bool {
        sourceMs + readyLeadMs < finalUpToMs
    }

    /// One partial result an export drew from, and the source times it drew over.
    public struct Use: Sendable {
        public var detections: [SensitiveDataDetection]
        public var finalUpToMs: Double
        public var fromMs: Double
        public var toMs: Double

        public init(detections: [SensitiveDataDetection], finalUpToMs: Double, fromMs: Double, toMs: Double) {
            self.detections = detections
            self.finalUpToMs = finalUpToMs
            self.fromMs = fromMs
            self.toMs = toMs
        }
    }

    /// Whether `result` covers what every used partial result covered: over each drawn range
    /// widened by the margin, cut off where that partial result was final.
    public static func isConsistent(_ uses: [Use], with result: [SensitiveDataDetection]) -> Bool {
        for use in uses {
            let fromMs = use.fromMs - compareMarginMs
            let untilMs = min(use.finalUpToMs, use.toMs + compareMarginMs)
            if signature(use.detections, fromMs: fromMs, untilMs: untilMs) != signature(result, fromMs: fromMs, untilMs: untilMs) { return false }
        }
        return true
    }

    /// The covers of `detections` over `fromMs..<untilMs`: each overlapping detection with its
    /// session, kind, clipped span, video size and the keyframes reaching into the range (one
    /// before, one after), one line each, in sorted order.
    public static func signature(_ detections: [SensitiveDataDetection], fromMs: Double, untilMs: Double) -> String {
        func number(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        }
        return detections.filter { $0.startMs < untilMs && $0.endMs > fromMs }.map { d -> String in
            let keys = d.keyframes
            let first = keys.firstIndex { $0.timeMs >= fromMs }
            let last = keys.firstIndex { $0.timeMs >= untilMs }
            let lower = first.map { max(0, $0 - 1) } ?? keys.count - 1
            let upper = last.map { $0 + 1 } ?? keys.count
            let slice = lower < upper ? keys[max(lower, 0)..<min(upper, keys.count)].map { k in
                "[" + [k.timeMs, k.x, k.y, k.width, k.height].map(number).joined(separator: ",") + "]"
            } : []
            return "[" + [String(d.sessionIndex), "\"" + d.kind.rawValue + "\"", number(max(d.startMs, fromMs)), number(min(d.endMs, untilMs)),
                          number(d.videoWidthPx), number(d.videoHeightPx), "[" + slice.joined(separator: ",") + "]"].joined(separator: ",") + "]"
        }.sorted().joined(separator: "\n")
    }
}

/// The scan's results kept in the project (`cache/sensitive-data_v1.json`).
public struct SensitiveDataScan: Codable, Sendable {
    /// Inputs the detections were found with.
    public var customPhrases: [String]
    public var detectFaces: Bool
    public var detections: [SensitiveDataDetection]
    /// Recording time up to which results are final.
    public var finalUpToMs: Double
    public var isComplete: Bool
    /// While scanning: the detections of the chunks scanned ahead, resolved on their own.
    public var provisionalDetections: [SensitiveDataDetection]
    /// While scanning: the result of the last finished scan of this project with other inputs.
    public var previousDetections: [SensitiveDataDetection]

    public init(customPhrases: [String], detectFaces: Bool, detections: [SensitiveDataDetection], finalUpToMs: Double, isComplete: Bool,
                provisionalDetections: [SensitiveDataDetection] = [], previousDetections: [SensitiveDataDetection] = []) {
        self.customPhrases = customPhrases
        self.detectFaces = detectFaces
        self.detections = detections.sorted { $0.startMs < $1.startMs }
        self.finalUpToMs = finalUpToMs
        self.isComplete = isComplete
        self.provisionalDetections = provisionalDetections
        self.previousDetections = previousDetections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customPhrases = try c.decode([String].self, forKey: .customPhrases)
        detectFaces = try c.decode(Bool.self, forKey: .detectFaces)
        detections = try c.decode([SensitiveDataDetection].self, forKey: .detections)
        finalUpToMs = try c.decode(Double.self, forKey: .finalUpToMs)
        isComplete = try c.decode(Bool.self, forKey: .isComplete)
        provisionalDetections = try c.decodeIfPresent([SensitiveDataDetection].self, forKey: .provisionalDetections) ?? []
        previousDetections = try c.decodeIfPresent([SensitiveDataDetection].self, forKey: .previousDetections) ?? []
    }

    /// What the preview covers: the finished result; while scanning, the partial detections, those
    /// scanned ahead and the last finished result, in start order.
    public var previewDetections: [SensitiveDataDetection] {
        if isComplete { return detections }
        return (detections + provisionalDetections + previousDetections).sorted { $0.startMs < $1.startMs }
    }

    public static func url(bundle: URL) -> URL {
        bundle.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("sensitive-data_v1.json")
    }

    public static func load(bundle: URL) -> SensitiveDataScan? {
        guard let data = try? Data(contentsOf: url(bundle: bundle)) else { return nil }
        return try? JSONDecoder().decode(SensitiveDataScan.self, from: data)
    }

    public func save(bundle: URL) throws {
        let url = Self.url(bundle: bundle)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public func matches(_ config: ProcessingConfig) -> Bool {
        customPhrases == config.sensitiveDataCustomPhrases && detectFaces == config.autoMaskFaces
    }
}
