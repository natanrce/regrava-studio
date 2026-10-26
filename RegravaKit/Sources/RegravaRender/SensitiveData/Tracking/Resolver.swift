import CoreGraphics
import Foundation

// Resolving: joins the stored evidence of every chunk into one timeline, tracks it into items,
// adds the followed faces, refines the item edges to the exact frame and renders the result as
// the detection dictionaries handed to the editor.

extension SD {
    final class SensitiveDataResolver {
        let scanner: Scanner
        let cache: SensitiveDataCache
        let layers: ChunkLayers
        /// Whether newly refined edges are kept in `edgeMemo` and written to the cache.
        let remembersDecisions: Bool
        var edgeMemo: [UInt64: Double]
        /// Face tracks already followed, by piece.
        var faceTracks: [Int: [FaceTrack]]
        let memoLock: NSLock

        init(scanner: Scanner, cache: SensitiveDataCache, layers: ChunkLayers, remembersDecisions: Bool,
             edgeMemo: [UInt64: Double], faceTracks: [Int: [FaceTrack]] = [:]) {
            self.scanner = scanner
            self.cache = cache
            self.layers = layers
            self.remembersDecisions = remembersDecisions
            self.edgeMemo = edgeMemo
            self.faceTracks = faceTracks
            memoLock = NSLock()
        }

        struct Resolved {
            var items: [TrackedItem]
            var trackingSeconds: Double
            var faceFollowSeconds: Double
            var faceFollowDecodedFrames: Int
            var faceFollowedFrames: Int
            var edgeSeconds: Double
            var refinedEdges: Int
            var edgeDecodedFrames: Int
            var edgeOcrReads: Int
        }

        /// The items of `chunks` (consecutive stored chunks) up to `endMs`. Edges are refined only
        /// when final, or when everything they depend on lies before `endMs`.
        func resolve(_ chunks: [StoredChunk], endMs: Int, isFinal: Bool) -> Resolved {
            var resolved = Resolved(items: [], trackingSeconds: 0, faceFollowSeconds: 0, faceFollowDecodedFrames: 0,
                                    faceFollowedFrames: 0, edgeSeconds: 0, refinedEdges: 0, edgeDecodedFrames: 0, edgeOcrReads: 0)
            let trackingStart = CFAbsoluteTimeGetCurrent()

            // Every read with the findings of the phrase layers and the faces added.
            var observations: [Observation] = []
            for chunk in chunks {
                for (readIndex, read) in chunk.evidence.reads.enumerated() {
                    var findings = read.findings
                    for layer in layers.phrases {
                        findings.append(contentsOf: chunk.phrases[layer.id]?.findingsByRead[readIndex] ?? [])
                    }
                    if let faces = chunk.faces {
                        findings.append(contentsOf: faces.facesByRead[readIndex])
                    }
                    observations.append(Observation(timeMs: read.timeMs, region: read.region, faceRegion: read.faceRegion,
                                                    lines: read.lines, findings: findings, firstTile: read.firstTile,
                                                    tileSignatures: read.tileSignatures))
                }
            }
            observations = observations.enumerated().sorted { a, b in
                if a.element.timeMs != b.element.timeMs { return a.element.timeMs < b.element.timeMs }
                let ay = a.element.region.minY
                let by = b.element.region.minY
                if ay != by { return ay < by }
                return a.offset < b.offset
            }.map(\.element)
            var samples: [ChangeSample] = []
            for chunk in chunks { samples.append(contentsOf: chunk.evidence.changeSamples) }
            samples.sort { $0.timeMs < $1.timeMs }
            var sampledTimesMs: [Int] = []
            for chunk in chunks { sampledTimesMs.append(contentsOf: chunk.evidence.sampledTimesMs) }
            sampledTimesMs = sampledTimesMs.sorted()

            let grid = scanner.grid
            let timeline = ChangeTimeline(samples: samples)
            let tracker = Tracker(observations: observations, timeline: timeline, grid: grid, options: SD.options,
                                  durationMs: endMs)
            var items = tracker.track()
            let trackingEnd = CFAbsoluteTimeGetCurrent()
            resolved.trackingSeconds = trackingEnd - trackingStart

            if layers.faceLayer != nil {
                let tracks = faceTracks(observations: observations, samples: samples, sampledTimesMs: sampledTimesMs,
                                        endMs: endMs, isFinal: isFinal, resolved: &resolved)
                var nextId = (items.map(\.id).max() ?? 0) + 1
                var stepsByStripe: [Int: [(timeMs: Double, dy: CGFloat?)]] = [:]
                let frameRect = CGRect(x: 0, y: 0, width: CGFloat(grid.widthPx), height: CGFloat(grid.heightPx))
                var faceItems: [TrackedItem] = []
                let sorted = tracks.sorted { $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs }
                for track in sorted {
                    // A track without boxes has nothing to cover from: the scan fails (and stops).
                    guard !track.boxes.isEmpty else {
                        SD.fail("A face track from \(track.startMs) to \(track.endMs) ms has no boxes")
                        break
                    }
                    let stripe = grid.stripe(ofX: track.boxes[0].rect.midX)
                    let steps = stepsByStripe[stripe] ?? SD.scrollSteps(ofStripe: stripe, in: timeline)
                    stepsByStripe[stripe] = steps
                    let carried = SD.carriedAlongScroll(track, scrollSteps: steps, frameRect: frameRect)
                    let cover = SD.steadyFaceCover(carried, scrollSteps: steps)
                    let first = cover[0]
                    let firstMs = Int(first.timeMs.rounded(.down))
                    let item = TrackedItem(id: nextId, kind: "face", text: "face", key: "face",
                                           startMs: Int(carried.startMs.rounded(.down)), endMs: 0, lastSeenMs: firstMs,
                                           lastSeenRect: first.rect, keyframes: [(timeMs: firstMs, rect: first.rect)],
                                           endIfGoneMs: 0)
                    nextId += 1
                    item.heldKeyframes = cover
                    item.endMs = Int(carried.endMs.rounded(.up))
                    item.exactStartMs = carried.startMs
                    item.exactEndMs = carried.endMs
                    faceItems.append(item)
                }
                items = items.filter { $0.kind != "face" }
                items.append(contentsOf: faceItems)
            }

            let edgeStart = CFAbsoluteTimeGetCurrent()
            memoLock.lock()
            let memo = edgeMemo
            let refiner = EdgeRefiner(scanner: scanner, timeline: timeline, sampledTimesMs: sampledTimesMs, memo: memo)
            memoLock.unlock()
            refiner.refine(items) { edge in
                if isFinal { return true }
                guard edge.presentMs < endMs else { return false }
                return edge.candidates.allSatisfy { $0.changeMs < endMs }
            }
            if remembersDecisions && !refiner.newlyDecided.isEmpty {
                memoLock.lock()
                edgeMemo.merge(refiner.newlyDecided) { _, decided in decided }
                memoLock.unlock()
                try? cache.writeEdges(refiner.newlyDecided)
            }
            resolved.edgeSeconds = CFAbsoluteTimeGetCurrent() - edgeStart
            resolved.items = items
            resolved.refinedEdges = refiner.refinedEdges
            resolved.edgeDecodedFrames = refiner.decodedFrames
            resolved.edgeOcrReads = refiner.ocrReads
            return resolved
        }
    }

    /// The detections handed to the editor: one dictionary per item with its id, kind, text
    /// (masked when text redaction is on), start/end (exact edges rounded down to 0.001 ms) and
    /// keyframes (whole pixels, grown to cover partial pixels).
    static func detectionObjects(_ items: [TrackedItem]) -> [[String: Any]] {
        items.map { item -> [String: Any] in
            let path = item.heldKeyframes ?? item.keyframes.map { (timeMs: Double($0.timeMs), rect: $0.rect) }
            let keyframes = path.map { keyframe -> [String: Any] in
                var timeMs = keyframe.timeMs
                if item.heldKeyframes != nil { timeMs = (timeMs * 1000).rounded(.down) / 1000 }
                return [
                    "timeMs": timeMs,
                    "x": Int(keyframe.rect.minX.rounded(.down)),
                    "y": Int(keyframe.rect.minY.rounded(.down)),
                    "width": Int(keyframe.rect.width.rounded(.up)) + 1,
                    "height": Int(keyframe.rect.height.rounded(.up)) + 1,
                ]
            }
            var text = item.text
            if SD.options.isTextRedacted {
                if text.count < 3 {
                    text = "**"
                } else {
                    text = String(text.prefix(2)) + String(repeating: "*", count: text.count - 2)
                }
            }
            let startMs: Double = item.exactStartMs.map { Double(Int($0 * 1000)) / 1000 } ?? Double(item.startMs)
            let endMs: Double = item.exactEndMs.map { Double(Int($0 * 1000)) / 1000 } ?? Double(item.endMs)
            return [
                "id": item.id,
                "kind": item.kind,
                "text": text,
                "startMs": startMs,
                "endMs": endMs,
                "isTyped": item.isTyped,
                "keyframes": keyframes,
            ]
        }
    }
}
