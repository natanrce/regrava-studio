@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

// EdgeRefiner moves the start/end of every
// tracked item from the sampled grid (50 ms) to the exact video frame: it decodes the frames of
// the gap between the last sample with the item and the first sample without it, crops the
// item's rect out of each frame and finds the frame where the crop stops (or starts) looking like
// the item, reading it with accurate OCR when the look alone is not decisive.

extension SD {
    final class EdgeRefiner {
        let scanner: Scanner
        let timeline: ChangeTimeline
        let sampledTimesMs: [Int]
        let lock: NSLock
        var refinedEdges: Int
        var decodedFrames: Int
        var ocrReads: Int
        /// Decisions already taken, by `memoKey`: the exact time, or NaN for "no exact time".
        var memo: [UInt64: Double]
        /// Decisions taken by this refiner (the resolver writes them to `edges.memo`).
        var newlyDecided: [UInt64: Double]

        /// Starts with no stats and no new decisions; `memo` holds the decisions of earlier passes.
        init(scanner: Scanner, timeline: ChangeTimeline, sampledTimesMs: [Int], memo: [UInt64: Double]) {
            self.scanner = scanner
            self.timeline = timeline
            self.sampledTimesMs = sampledTimesMs
            lock = NSLock()
            refinedEdges = 0
            decodedFrames = 0
            ocrReads = 0
            self.memo = memo
            newlyDecided = [:]
        }

        struct Edge {
            let item: TrackedItem
            let isStart: Bool
            /// The item's rect grown by max(40% of its height, 6 px), clipped to the frame, integral.
            let cropRect: CGRect
            /// A sample time at which the item is known to be present.
            let presentMs: Int
            /// Every sample in the gap whose tiles under the item changed, with the sample before it.
            let candidates: [(previousMs: Int, changeMs: Int)]
        }

        struct Request {
            let edge: Int
            let fromMs: Int
            let toMs: Int
        }

        // MARK: edge(of:isStart:)

        func edge(of item: TrackedItem, isStart: Bool) -> Edge? {
            let rect: CGRect
            let fromMs: Int
            let toMs: Int
            let presentMs: Int
            if isStart {
                rect = item.keyframes[0].rect
                guard let evidence = item.startEvidence else { return nil }
                fromMs = evidence.absentMs
                toMs = evidence.presentMs
                presentMs = evidence.presentMs
            } else {
                guard let evidence = item.endEvidence else { return nil }
                rect = item.lastSeenRect
                fromMs = evidence.presentMs
                toMs = evidence.absentMs
                presentMs = evidence.presentMs
            }
            let grid = scanner.grid
            let tiles = grid.tiles(in: rect)
            let samples = timeline.samples
            // First sample after fromMs.
            var low = 0
            var high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].timeMs <= fromMs { low = mid + 1 } else { high = mid }
            }
            var changesMs: [Int] = []
            var index = low
            while index < samples.count {
                let sample = samples[index]
                if sample.timeMs > toMs { break }
                if sample.hasChange(inAnyOf: tiles) { changesMs.append(sample.timeMs) }
                index += 1
            }
            guard !changesMs.isEmpty, changesMs.count <= 6 else { return nil }
            let grownBy = rect.height * 0.4 >= 6 ? rect.height * 0.4 : 6
            let frame = CGRect(x: 0, y: 0, width: Double(grid.widthPx), height: Double(grid.heightPx))
            let cropRect = rect.insetBy(dx: -grownBy, dy: -grownBy).intersection(frame).integral
            guard cropRect.width >= 8, cropRect.height >= 8 else { return nil }
            let candidates = changesMs.map { changeMs -> (previousMs: Int, changeMs: Int) in
                var previousMs = changeMs
                if !sampledTimesMs.isEmpty {
                    // First sampled time at or after the change; the one before it.
                    var low = 0
                    var high = sampledTimesMs.count
                    while low < high {
                        let mid = (low + high) / 2
                        if sampledTimesMs[mid] < changeMs { low = mid + 1 } else { high = mid }
                    }
                    if low > 0 { previousMs = sampledTimesMs[low - 1] }
                }
                return (previousMs: previousMs, changeMs: changeMs)
            }
            return Edge(item: item, isStart: isStart, cropRect: cropRect, presentMs: presentMs, candidates: candidates)
        }

        // MARK: refine(_:isDue:)

        func refine(_ items: [TrackedItem], isDue: (Edge) -> Bool) {
            var edges: [Edge] = []
            for item in items {
                edges.append(contentsOf: [edge(of: item, isStart: true), edge(of: item, isStart: false)].compactMap { $0 })
            }
            let due = edges.filter(isDue)
            guard !due.isEmpty else { return }
            let decided = Decided(count: due.count)
            var pending: [Int] = []
            for (index, edge) in due.enumerated() {
                if let timeMs = memo[Self.memoKey(edge)] {
                    decided.values[index] = timeMs.isNaN ? nil : timeMs
                } else {
                    pending.append(index)
                }
            }
            var requests: [Request] = []
            for index in pending {
                let edge = due[index]
                requests.append(Request(edge: index, fromMs: edge.presentMs, toMs: edge.presentMs))
                for candidate in edge.candidates {
                    requests.append(Request(edge: index, fromMs: candidate.previousMs, toMs: candidate.changeMs))
                }
            }
            if !requests.isEmpty {
                let frames = fetchCrops(requests, edges: due)
                DispatchQueue.concurrentPerform(iterations: pending.count) { k in
                    let index = pending[k]
                    let timeMs = edgeFrameMs(due[index], frames: frames[index])
                    lock.lock()
                    decided.values[index] = timeMs
                    lock.unlock()
                }
                for index in pending {
                    let key = Self.memoKey(due[index])
                    memo[key] = decided.values[index] ?? .nan
                    newlyDecided[key] = decided.values[index] ?? .nan
                }
            }
            for (index, edge) in due.enumerated() {
                guard let timeMs = decided.values[index] else { continue }
                let item = edge.item
                if edge.isStart {
                    if timeMs < Double(item.endMs) {
                        item.startMs = Int(timeMs.rounded(.down))
                        item.exactStartMs = timeMs
                        refinedEdges += 1
                    }
                } else if Double(item.startMs) < timeMs {
                    item.endMs = Int(timeMs.rounded(.up))
                    item.exactEndMs = timeMs
                    refinedEdges += 1
                }
            }
        }

        /// The `[Double?]` refine's concurrent closure writes.
        private final class Decided: @unchecked Sendable {
            var values: [Double?]
            init(count: Int) { values = Array(repeating: nil, count: count) }
        }

        // MARK: fetchCrops(_:edges:)

        /// Decodes the frames every request needs (requests closer than 1 s share one decode pass)
        /// and returns, per edge, the crop of its rect in each decoded frame of its requests.
        func fetchCrops(_ requests: [Request], edges: [Edge]) -> [[(timeMs: Double, crop: GrayImage)]] {
            var groups: [[Request]] = []
            for request in requests.sorted(by: { $0.fromMs < $1.fromMs }) {
                if let lastToMs = groups.last?.map(\.toMs).max(), request.fromMs - lastToMs < 1000 {
                    groups[groups.count - 1].append(request)
                } else {
                    groups.append([request])
                }
            }
            let shared = FetchState(count: edges.count)
            let groupLock = NSLock()
            let iterations = min(scanner.options.decodeThreads, groups.count)
            DispatchQueue.concurrentPerform(iterations: iterations) { _ in
                while true {
                    groupLock.lock()
                    let groupIndex = shared.nextGroup
                    shared.nextGroup = groupIndex + 1
                    groupLock.unlock()
                    guard groupIndex < groups.count else { return }
                    let group = groups[groupIndex]
                    let fromMs = group.map(\.fromMs).min()!
                    let toMs = group.map(\.toMs).max()!
                    let frames = scanner.makeChunkFrames(purpose: "sensitive data edges", startMs: max(fromMs - 1, 0), endMs: toMs + 2)
                    let lastMs = Double(toMs)
                    func wanting(_ timeMs: Double) -> [Request] {
                        group.filter { Double($0.fromMs) - 1 <= timeMs && timeMs <= Double($0.toMs) + 1 }
                    }
                    var decoded = 0
                    var found: [(edge: Int, timeMs: Double, crop: GrayImage)] = []
                    while true {
                        let next = autoreleasepool { frames.next(isNeeded: { !wanting($0).isEmpty }) }
                        guard let (buffer, timeMs, _) = next else { break }
                        decoded += 1
                        if lastMs + 1 < timeMs { break }
                        let wanted = wanting(timeMs)
                        guard !wanted.isEmpty else { continue }
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                        for edge in Set(wanted.map(\.edge)) {
                            if let crop = SD.makeGrayImage(luma: luma, rowBytes: rowBytes, rect: edges[edge].cropRect) {
                                found.append((edge: edge, timeMs: timeMs, crop: crop))
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    }
                    lock.lock()
                    for frame in found where !shared.crops[frame.edge].contains(where: { $0.timeMs == frame.timeMs }) {
                        shared.crops[frame.edge].append((timeMs: frame.timeMs, crop: frame.crop))
                    }
                    decodedFrames += decoded
                    lock.unlock()
                }
            }
            return shared.crops
        }

        /// The locals fetchCrops' concurrent closure shares.
        private final class FetchState: @unchecked Sendable {
            var crops: [[(timeMs: Double, crop: GrayImage)]]
            var nextGroup = 0
            init(count: Int) { crops = Array(repeating: [], count: count) }
        }

        // MARK: edgeFrameMs(_:frames:)

        /// The exact time of the edge: the first frame showing the item (start) or the first frame
        /// no longer showing it (end); nil without a frame at `presentMs`.
        func edgeFrameMs(_ edge: Edge, frames: [(timeMs: Double, crop: GrayImage)]) -> Double? {
            func crop(atMs timeMs: Int) -> GrayImage? {
                let target = Double(timeMs)
                guard let nearest = frames.min(by: { abs($0.timeMs - target) < abs($1.timeMs - target) }),
                      abs(nearest.timeMs - target) <= 1 else { return nil }
                return nearest.crop
            }
            guard let present = crop(atMs: edge.presentMs) else { return nil }

            func isPresent(_ image: GrayImage) -> Bool {
                if isSameLook(image, present, toleranceLevels: 8) { return true }
                lock.lock()
                ocrReads += 1
                lock.unlock()
                let item = edge.item
                if item.kind == "face" {
                    let center = CGPoint(x: edge.cropRect.midX, y: edge.cropRect.midY)
                    for face in SD.visionFaces(in: image)
                    where face.insetBy(dx: face.width * -0.5, dy: face.height * -0.5).contains(center) {
                        return true
                    }
                    return false
                }
                let keys = SD.recognizeText(image, level: .accurate).map { SD.foldedKey($0.text.string) }
                for key in keys {
                    let characters = Array(item.key)
                    guard !characters.isEmpty else { continue }
                    let length = min(characters.count, 6)
                    for start in 0...(characters.count - length)
                    where key.contains(String(characters[start..<(start + length)])) {
                        return true
                    }
                }
                if edge.isStart {
                    // Typing in progress: what is read is the start of the key.
                    if keys.contains(where: { !$0.isEmpty && item.key.hasPrefix($0) }) { return true }
                    return !keys.contains { !$0.isEmpty }
                }
                return false
            }

            let candidates = edge.candidates
            var window = edge.isStart ? candidates.first! : candidates.last!
            for (index, candidate) in candidates.enumerated() where edge.isStart || index != candidates.count - 1 {
                if let image = crop(atMs: candidate.changeMs), isPresent(image) == edge.isStart {
                    window = candidate
                    break
                }
            }
            let fromMs = Double(window.previousMs) - 1
            let toMs = Double(window.changeMs) + 1
            let span = frames.filter { fromMs <= $0.timeMs && $0.timeMs <= toMs }.sorted { $0.timeMs < $1.timeMs }
            guard span.count >= 2 else { return span.last?.timeMs }
            let first = span[0]
            if edge.isStart {
                for frame in span.dropFirst() where !isSameLook(frame.crop, first.crop, toleranceLevels: 3) {
                    return frame.timeMs
                }
                return span[span.count - 1].timeMs
            }
            let last = span[span.count - 1]
            var held: (crop: GrayImage, isPresent: Bool)?
            for frame in span.dropFirst() {
                if isSameLook(frame.crop, first.crop, toleranceLevels: 8) { continue }
                if isSameLook(frame.crop, last.crop, toleranceLevels: 8) { return frame.timeMs }
                if let held, isSameLook(frame.crop, held.crop, toleranceLevels: 8) {
                    if held.isPresent { continue }
                    return frame.timeMs
                }
                if isPresent(frame.crop) {
                    held = (crop: frame.crop, isPresent: true)
                    continue
                }
                return frame.timeMs
            }
            return last.timeMs
        }

        // MARK: isSameLook(_:_:toleranceLevels:)

        /// Same size, and in every 8×8 block (clipped at the edges) the mean gray difference is at
        /// most `toleranceLevels` levels: |Σ(b − a)| ≤ toleranceLevels × pixels.
        func isSameLook(_ a: GrayImage, _ b: GrayImage, toleranceLevels: Int) -> Bool {
            guard a.widthPx == b.widthPx, a.heightPx == b.heightPx else { return false }
            return a.bytes.withUnsafeBytes { aBytes in
                b.bytes.withUnsafeBytes { bBytes in
                    let blockPx = 8
                    let widthPx = a.widthPx
                    let heightPx = a.heightPx
                    for y0 in stride(from: 0, to: heightPx, by: blockPx) {
                        let y1 = min(y0 + blockPx, heightPx)
                        for x0 in stride(from: 0, to: widthPx, by: blockPx) {
                            let x1 = min(x0 + blockPx, widthPx)
                            var difference = 0
                            var pixels = 0
                            for y in y0..<y1 {
                                let row = y * widthPx
                                for x in x0..<x1 {
                                    difference += Int(bBytes[row + x]) - Int(aBytes[row + x])
                                    pixels += 1
                                }
                            }
                            if toleranceLevels * pixels < abs(difference) { return false }
                        }
                    }
                    return true
                }
            }
        }

        // MARK: memoKey(_:)

        /// fnv1a64 of "kind|key|isStart|x,y,w,h|presentMs|prev-change,…".
        static func memoKey(_ edge: Edge) -> UInt64 {
            let rect = edge.cropRect
            let rectText = [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)]
                .map(\.description).joined(separator: ",")
            let candidatesText = edge.candidates.map { $0.previousMs.description + "-" + $0.changeMs.description }
                .joined(separator: ",")
            let text = "\(edge.item.kind)|\(edge.item.key)|\(edge.isStart)|\(rectText)|\(edge.presentMs)|\(candidatesText)"
            return SD.fnv1a64(Data(text.utf8))
        }
    }
}
