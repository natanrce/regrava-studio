import CoreGraphics
import Darwin
import Dispatch
import Foundation
import Vision

// The scan driver: chunk grid and evidence cache set-up, the chunk sweep over decode lanes, partial
// results while chunks arrive, and the final resolve with its statistics.

extension SD {
    /// The options of the scan in progress (read by the sweep and by partial results).
    nonisolated(unsafe) static var options = Options()

    /// A fatal scan failure (a video that cannot be read or decoded, a chunk that cannot be stored).
    /// The first one is kept; the scan stops at its next check and throws it. The scan runs inside the
    /// app's process, so a failure ends the scan, never the process.
    static let failureLock = NSLock()
    nonisolated(unsafe) static var failureMessage: String?

    @discardableResult
    static func fail(_ message: String) -> SensitiveDataScanError {
        failureLock.lock()
        if failureMessage == nil { failureMessage = message }
        failureLock.unlock()
        return SensitiveDataScanError(message: message)
    }

    static var failure: SensitiveDataScanError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failureMessage.map { SensitiveDataScanError(message: $0) }
    }

    /// Runs one fast and one accurate text recognition on a blank 64×32 gray image so the models are loaded.
    static func warmUpTextRecognition() {
        let bytes = Data(count: 2048)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return }
        guard let image = CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        let gray = GrayImage(bytes: bytes, widthPx: 64, heightPx: 32, originPx: .zero, cgImage: image)
        _ = recognizeText(gray, level: .fast)
        _ = recognizeText(gray, level: .accurate)
    }

    /// The chunk the demanded time falls in: the first chunk ending after it, else the last chunk.
    fileprivate static func demandChunk(_ demandMs: Int, in grid: ChunkGrid) -> Int {
        grid.endsMs.firstIndex(where: { demandMs < $0 }) ?? grid.endsMs.count - 1
    }

    fileprivate static func chunkRange(_ index: Int, in grid: ChunkGrid) -> (startMs: Int, endMs: Int) {
        (index == 0 ? 0 : grid.endsMs[index - 1], grid.endsMs[index])
    }

    // MARK: ChunkStore

    /// The chunks available so far (from the cache or just computed), by chunk index.
    final class ChunkStore {
        let chunkCount: Int
        let lock = NSLock()
        var chunks: [Int: StoredChunk] = [:]

        init(chunkCount: Int) {
            self.chunkCount = chunkCount
        }

        /// The leading run of consecutive chunks 0, 1, 2… that are all available.
        func prefix() -> [StoredChunk] {
            lock.lock()
            var result: [StoredChunk] = []
            while let chunk = chunks[result.count] {
                result.append(chunk)
            }
            lock.unlock()
            return result
        }

        /// The run of consecutive available chunks containing `chunk` (empty when `chunk` itself is missing).
        func island(around chunk: Int) -> [StoredChunk] {
            lock.lock()
            defer { lock.unlock() }
            guard chunks[chunk] != nil else { return [] }
            var lower = chunk
            while lower > 0, chunks[lower - 1] != nil {
                lower -= 1
            }
            var upper = chunk
            while upper < chunkCount - 1, chunks[upper + 1] != nil {
                upper += 1
            }
            var result: [StoredChunk] = []
            for index in lower...upper {
                if let stored = chunks[index] { result.append(stored) }
            }
            return result
        }
    }

    // MARK: PartialResults

    /// Re-resolves the available chunks while the sweep runs and delivers interim outputs: the prefix of
    /// finished chunks, plus a provisional island around the demanded chunk.
    final class PartialResults {
        let store: ChunkStore
        let resolver: SensitiveDataResolver
        let cache: SensitiveDataCache
        let island: (chunk: Int, resolver: SensitiveDataResolver)?
        let deliver: (ScanOutput) -> Void
        let queue: DispatchQueue
        let lock = NSLock()
        var isScheduled = false
        var isFinished = false
        var resolvedChunkCount = 0
        var resolvedIslandChunks: [Int] = []
        var lastPrefix: (detections: [[String: Any]], endMs: Int) = ([], 0)
        var lastIsland: ProvisionalIsland?
        var lastPassSeconds = 0.0
        var deliveredCount = 0

        init(store: ChunkStore, resolver: SensitiveDataResolver, cache: SensitiveDataCache,
             island: (chunk: Int, resolver: SensitiveDataResolver)?, deliver: @escaping (ScanOutput) -> Void) {
            self.store = store
            self.resolver = resolver
            self.cache = cache
            self.island = island
            self.deliver = deliver
            queue = DispatchQueue(label: "sensitive-data.partial", qos: .unspecified, attributes: [],
                                  autoreleaseFrequency: .inherit, target: nil)
        }

        /// Schedules one pass unless one is pending: immediately for the first delivery, then after
        /// max(last pass duration, 2 s).
        func chunkStored() {
            lock.lock()
            if !isScheduled, !isFinished {
                isScheduled = true
                let delaySeconds = deliveredCount != 0 ? max(lastPassSeconds, 2.0) : 0
                queue.asyncAfter(deadline: .now() + delaySeconds, qos: .unspecified, flags: []) { [self] in
                    pass()
                }
            }
            lock.unlock()
        }

        /// Stops further deliveries and waits for a pass in flight.
        func finish() {
            lock.lock()
            isFinished = true
            lock.unlock()
            queue.sync {}
        }

        private func pass() {
            lock.lock()
            isScheduled = false
            let finished = isFinished
            lock.unlock()
            if finished { return }
            let prefix = store.prefix()
            let grid = cache.grid
            guard prefix.count < grid.endsMs.count else { return }
            var islandChunks: [StoredChunk] = []
            if let island {
                islandChunks = store.island(around: island.chunk)
                // An island that starts at chunk 0 is part of the prefix.
                if islandChunks.isEmpty || islandChunks[0].evidence.chunkIndex < 1 {
                    islandChunks = []
                }
            }
            let islandIndices = islandChunks.map { $0.evidence.chunkIndex }
            let islandChanged = islandIndices != resolvedIslandChunks
            guard resolvedChunkCount < prefix.count || islandChanged else { return }
            let startTime = CFAbsoluteTimeGetCurrent()
            if resolvedChunkCount < prefix.count {
                let endMs = grid.endsMs[prefix.count - 1]
                let resolved = resolver.resolve(prefix, endMs: endMs, isFinal: false)
                lastPrefix = (SD.detectionObjects(resolved.items), endMs)
            }
            if islandChanged, let island {
                if let first = islandChunks.first, let last = islandChunks.last {
                    let fromMs = Double(SD.chunkRange(first.evidence.chunkIndex, in: grid).startMs)
                    let endMs = grid.endsMs[last.evidence.chunkIndex]
                    let resolved = island.resolver.resolve(islandChunks, endMs: endMs, isFinal: false)
                    lastIsland = ProvisionalIsland(detections: SD.detectionObjects(resolved.items), fromMs: fromMs,
                                                   toMs: Double(endMs))
                } else {
                    lastIsland = nil
                }
            }
            lock.lock()
            lastPassSeconds = CFAbsoluteTimeGetCurrent() - startTime
            resolvedChunkCount = prefix.count
            resolvedIslandChunks = islandIndices
            if isFinished {
                lock.unlock()
                return
            }
            deliveredCount += 1
            lock.unlock()
            let stats: [String: Any] = ["widthPx": cache.widthPx, "heightPx": cache.heightPx]
            let finalUpToMs = max(lastPrefix.endMs - SD.options.partialFinalLagMs, 0)
            if SD.failure != nil { return }
            deliver(ScanOutput(detections: lastPrefix.detections, stats: stats, finalUpToMs: Double(finalUpToMs),
                               analyzedUpToMs: Double(lastPrefix.endMs), provisional: lastIsland))
        }
    }

    // MARK: ChunkSweep

    /// Brings every chunk of the grid into the store: chunks already in the cache are loaded, the rest are
    /// claimed (so other processes scanning the same video share the work) and scanned on parallel lanes.
    final class ChunkSweep {
        let scanner: Scanner
        let cache: SensitiveDataCache
        let layers: ChunkLayers
        let store: ChunkStore
        let isCancelled: () -> Bool
        let lock = NSLock()
        var computedCount = 0
        var isStopped = false

        init(scanner: Scanner, cache: SensitiveDataCache, layers: ChunkLayers, store: ChunkStore,
             isCancelled: @escaping () -> Bool) {
            self.scanner = scanner
            self.cache = cache
            self.layers = layers
            self.store = store
            self.isCancelled = isCancelled
        }

        /// Chunk visiting order: natural order, or around the demanded chunk — sorted stably by
        /// (distance key, index) where chunks after the demand cost their distance and chunks before it
        /// twice their distance.
        static func order(chunkCount: Int, demandChunk: Int?) -> [Int] {
            guard let demandChunk else { return Array(0..<chunkCount) }
            func key(_ index: Int) -> Int {
                index - demandChunk >= 0 ? index - demandChunk : (demandChunk - index) * 2
            }
            var order = Array(0..<chunkCount)
            // The standard library sort is stable; ties are also broken by index.
            order.sort { key($0) == key($1) ? $0 < $1 : key($0) < key($1) }
            return order
        }

        private func chunk(_ index: Int) -> StoredChunk? {
            store.lock.lock()
            defer { store.lock.unlock() }
            return store.chunks[index]
        }

        private func put(_ stored: StoredChunk, at index: Int) {
            store.lock.lock()
            store.chunks[index] = stored
            store.lock.unlock()
        }

        private func lengthMs(_ index: Int) -> Int {
            let range = SD.chunkRange(index, in: cache.grid)
            return range.endMs - range.startMs
        }

        func run(onChunkStored: @escaping () -> Void) throws {
            let options = SD.options
            let order: [Int]
            if let chunkOrder = options.chunkOrder {
                order = chunkOrder
            } else {
                let count = cache.grid.endsMs.count
                order = Self.order(chunkCount: count, demandChunk: options.demandMs.map { SD.demandChunk($0, in: cache.grid) })
            }
            scanner.readAdmission.rank(by: order)
            var pending: [Int] = []
            let stats = scanner.stats
            for index in order {
                if let stored = storedChunk(index) {
                    put(stored, at: index)
                    stats.lock.lock()
                    stats.storedChunks += 1
                    stats.lock.unlock()
                    stats.addProgress(lengthMs(index), totalMs: scanner.durationMs)
                } else {
                    pending.append(index)
                }
            }
            if !pending.isEmpty {
                onChunkStored()
            }
            let lanes = max(min(pending.count, options.decodeThreads), 1)
            let shared = Pending(pending)
            let pendingLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: lanes) { _ in
                work(pending: shared, pendingLock: pendingLock, onChunkStored: onChunkStored)
            }
            if let failure = SD.failure {
                throw failure
            }
            if isCancelled() {
                throw CancellationError()
            }
            if isStopped {
                throw ScanStoppedError()
            }
        }

        /// One lane: claim a missing chunk and scan it; when every missing chunk is claimed elsewhere, poll
        /// the cache every 0.5 s for the other process's results.
        /// The chunks still to bring in, shared by the lanes (guarded by the lanes' lock).
        final class Pending {
            var indices: [Int]
            init(_ indices: [Int]) { self.indices = indices }
        }

        private func work(pending: Pending, pendingLock: NSLock, onChunkStored: () -> Void) {
            while true {
                if isCancelled() || SD.failure != nil { return }
                lock.lock()
                let stopped = isStopped
                lock.unlock()
                if stopped { return }
                pendingLock.lock()
                let missing = pending.indices.filter { chunk($0) == nil }
                var claimed: Int?
                for index in missing where cache.claim(index) {
                    claimed = index
                    break
                }
                if let index = claimed {
                    pending.indices.removeAll { $0 == index }
                    pendingLock.unlock()
                    if let stored = storedChunk(index) {
                        put(stored, at: index)
                        onChunkStored()
                    } else {
                        guard let lane = SD.DecodeLanes.shared.acquire(isCancelled: { [self] in
                            if isCancelled() { return true }
                            lock.lock()
                            defer { lock.unlock() }
                            return isStopped
                        }) else {
                            cache.release(index)
                            return
                        }
                        let stored: StoredChunk
                        do {
                            stored = try complete(index)
                        } catch {
                            SD.fail("Cannot store chunk \(index): \((error as? SensitiveDataScanError)?.message ?? String(describing: error))")
                            lane.release()
                            cache.release(index)
                            return
                        }
                        put(stored, at: index)
                        onChunkStored()
                        lane.release()
                    }
                    cache.release(index)
                    continue
                }
                pendingLock.unlock()
                if missing.isEmpty { return }
                for index in missing where chunk(index) == nil {
                    if let stored = storedChunk(index) {
                        put(stored, at: index)
                        scanner.stats.addProgress(lengthMs(index), totalMs: scanner.durationMs)
                        onChunkStored()
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        /// A chunk whose evidence and every layer are in the cache.
        func storedChunk(_ index: Int) -> StoredChunk? {
            guard let evidence = cache.readEvidence(index) else { return nil }
            var faces: ChunkFaces?
            if let faceLayer = layers.faceLayer {
                guard let stored = cache.readFaces(faceLayer, index), stored.facesByRead.count == evidence.reads.count
                else { return nil }
                faces = stored
            }
            var phrases: [String: ChunkPhrase] = [:]
            for layer in layers.phrases {
                guard let phrase = cache.readPhrase(layer.id, index) else { return nil }
                phrases[layer.id] = phrase
            }
            return StoredChunk(evidence: evidence, faces: faces, phrases: phrases)
        }

        /// Scans the chunk (or, when its evidence is cached, only the missing layers), writes the results to
        /// the cache and reads the chunk back.
        func complete(_ index: Int) throws -> StoredChunk {
            let (startMs, endMs) = SD.chunkRange(index, in: cache.grid)
            let scan: ChunkScan
            let faceLayer: String?
            if let evidence = cache.readEvidence(index) {
                var missingFaceLayer = layers.faceLayer
                if let layer = missingFaceLayer, let faces = cache.readFaces(layer, index),
                   faces.facesByRead.count == evidence.reads.count {
                    missingFaceLayer = nil
                }
                var missingPhrases: [PhraseLayer] = []
                for layer in layers.phrases {
                    let url = cache.layerURL(layer.id, index)
                    do {
                        let file = try Data(contentsOf: url)
                        _ = try ChunkPhrase(decoding: try EvidenceFile.decode(file, version: 1))
                    } catch {
                        missingPhrases.append(layer)
                    }
                }
                faceLayer = missingFaceLayer
                scan = try scanner.fillLayers(evidence, startMs: startMs, endMs: endMs,
                                          layers: ChunkLayers(faceLayer: missingFaceLayer, phrases: missingPhrases))
                let stats = scanner.stats
                stats.lock.lock()
                stats.filledChunks += 1
                stats.lock.unlock()
                stats.addProgress(endMs - startMs, totalMs: scanner.durationMs)
            } else {
                faceLayer = layers.faceLayer
                scan = try scanner.readAdmission.scanning(index) {
                    try scanner.scanChunk(index, startMs: startMs, endMs: endMs, layers: layers)
                }
                try cache.write(scan.evidence.encoded(), version: 2, to: cache.evidenceURL(index))
                let stats = scanner.stats
                stats.lock.lock()
                stats.computedChunks += 1
                stats.lock.unlock()
                lock.lock()
                computedCount += 1
                if let stopAfter = SD.options.stopAfterComputedChunks, stopAfter <= computedCount {
                    isStopped = true
                }
                lock.unlock()
            }
            if let faces = scan.faces, let faceLayer {
                try cache.write(faces.encoded(), version: 2, to: cache.layerURL(faceLayer, index))
            }
            for (id, phrase) in scan.phrases {
                try cache.write(phrase.encoded(), version: 1, to: cache.layerURL(id, index))
            }
            guard let stored = storedChunk(index) else {
                throw SensitiveDataScanError(message: "chunk \(index) did not read back")
            }
            return stored
        }
    }

    // MARK: Scan

    /// Scans a video for sensitive data: builds the chunk grid and cache, sweeps the chunks (delivering
    /// partial results when `onPartialResult` is given), resolves the whole video and reports statistics.
    static func runSensitiveDataScan(_ options: Options, isCancelled: @escaping () -> Bool,
                                     onPartialResult: ((ScanOutput) -> Void)?) throws -> ScanOutput {
        SD.options = options
        failureLock.lock()
        failureMessage = nil
        failureLock.unlock()
        faceCascade = try options.faceCascadePath.map { try loadPicoCascade($0) }
        let scanner = try Scanner(options: options)
        let grid: ChunkGrid
        if let chunkMs = options.chunkMs {
            grid = ChunkGrid(endsMs: Array(stride(from: chunkMs, to: scanner.durationMs, by: chunkMs)) + [max(scanner.durationMs, 1)])
        } else {
            grid = ChunkGrid.forVideo(durationMs: scanner.durationMs, lanes: options.decodeThreads)
        }
        let cache = try SensitiveDataCache(videoPath: options.videoPath, root: options.cacheRoot, durationMs: scanner.durationMs,
                                           widthPx: scanner.grid.widthPx, heightPx: scanner.grid.heightPx, grid: grid,
                                           parameters: options.evidenceParameters)
        var faceLayer: String?
        if let path = options.faceCascadePath {
            let cascade = try Data(contentsOf: URL(fileURLWithPath: path))
            faceLayer = "faces-" + shortHash("2|\(fnv1a64(cascade))")
        }
        var phrases = options.customPhrases.map { PhraseLayer(phrase: $0) }
        phrases.sort { $0.id < $1.id }
        let layers = ChunkLayers(faceLayer: faceLayer, phrases: phrases)

        let warmUpStart = CFAbsoluteTimeGetCurrent()
        warmUpTextRecognition()
        let sweepStart = CFAbsoluteTimeGetCurrent()

        let resolver = SensitiveDataResolver(scanner: scanner, cache: cache, layers: layers, remembersDecisions: true,
                                             edgeMemo: cache.readEdges(), faceTracks: [:])
        let store = ChunkStore(chunkCount: cache.grid.endsMs.count)
        var partial: PartialResults?
        if let onPartialResult {
            var island: (chunk: Int, resolver: SensitiveDataResolver)?
            if let demandMs = options.demandMs {
                let chunk = demandChunk(demandMs, in: cache.grid)
                let islandResolver = SensitiveDataResolver(scanner: scanner, cache: cache, layers: layers,
                                                           remembersDecisions: false, edgeMemo: cache.readEdges(),
                                                           faceTracks: [:])
                island = (chunk, islandResolver)
            }
            partial = PartialResults(store: store, resolver: resolver, cache: cache, island: island, deliver: onPartialResult)
        }
        let sweep = ChunkSweep(scanner: scanner, cache: cache, layers: layers, store: store, isCancelled: isCancelled)
        try sweep.run(onChunkStored: { partial?.chunkStored() })
        partial?.finish()

        let sweepEnd = CFAbsoluteTimeGetCurrent()
        let prefix = store.prefix()
        precondition(prefix.count == cache.grid.endsMs.count)
        let resolved = resolver.resolve(prefix, endMs: scanner.durationMs, isFinal: true)
        if let failure = SD.failure { throw failure }
        cache.deleteOtherIdentities()
        let end = CFAbsoluteTimeGetCurrent()

        let stats = scanner.stats
        var byKind: [String: Int] = [:]
        for item in resolved.items {
            byKind[item.kind, default: 0] += 1
        }
        let ends = cache.grid.endsMs
        let middle = ends.count / 2
        let chunkMs = ends[middle] - (ends.count == 1 ? 0 : ends[middle - 1])
        let wallSeconds = end - sweepStart
        let output: [String: Any] = [
            "videoDurationSeconds": Double(scanner.durationMs) / 1000,
            "widthPx": scanner.grid.widthPx,
            "heightPx": scanner.grid.heightPx,
            "chunkMs": chunkMs,
            "chunks": ends.count,
            "computedChunks": stats.computedChunks,
            "storedChunks": stats.storedChunks,
            "filledChunks": stats.filledChunks,
            "layerDecodedFrames": stats.layerDecodedFrames,
            "partialResults": partial?.deliveredCount ?? 0,
            "decodedFrames": stats.decodedFrames,
            "skippedFrames": stats.skippedFrames,
            "eventFrames": stats.eventFrames,
            "sampledFrames": stats.sampledFrames,
            "changeSamples": stats.changeSamples,
            "ocrReads": stats.ocrJobs,
            "ocrFullFrameReads": stats.ocrFullFrameJobs,
            "ocrMegapixels": Double(stats.ocrPixels) / 1_000_000,
            "ocrBusySeconds": stats.ocrBusySeconds,
            "ocrAccurateSeconds": accurateTierStats.seconds,
            "ocrAccurateMegapixels": Double(accurateTierStats.pixels) / 1_000_000,
            "modelWarmUpSeconds": sweepStart - warmUpStart,
            "decodePhaseSeconds": sweepEnd - sweepStart,
            "ocrTailSeconds": 0.0,
            "trackingSeconds": resolved.trackingSeconds,
            "faceFollowSeconds": resolved.faceFollowSeconds,
            "faceFollowDecodedFrames": resolved.faceFollowDecodedFrames,
            "faceFollowedFrames": resolved.faceFollowedFrames,
            "edgeSeconds": resolved.edgeSeconds,
            "refinedEdges": resolved.refinedEdges,
            "edgeDecodedFrames": resolved.edgeDecodedFrames,
            "edgeOcrReads": resolved.edgeOcrReads,
            "faceVisionCalls": faceSearchStats.visionCalls,
            "faceVisionSeconds": faceSearchStats.visionSeconds,
            "facePicoSeconds": faceSearchStats.picoSeconds,
            "faceSearchedRegions": faceSearchStats.searchedRegions,
            "faceReusedRegions": faceSearchStats.reusedRegions,
            "wallSeconds": wallSeconds,
            "realtimeFactor": Double(scanner.durationMs) / 1000 / wallSeconds,
            "detections": resolved.items.count,
            "detectionsByKind": byKind,
        ]
        let durationMs = Double(scanner.durationMs)
        return ScanOutput(detections: detectionObjects(resolved.items), stats: output, finalUpToMs: durationMs,
                          analyzedUpToMs: durationMs, provisional: nil)
    }

    // MARK: Entry points

    /// One scan per process at a time.
    nonisolated(unsafe) static let scanLock = NSLock()

    /// Entry point for a scan request: rejects a concurrent scan, routes progress, normalises the phrases
    /// (trimmed of whitespace and newlines, empty ones dropped) and the demanded time (clamped at 0, whole ms).
    static func scan(videoPath: String, customPhrases: [String], faceCascadePath: String?, isTextRedacted: Bool,
                     demandMs: Double?, onPartialResult: ((ScanOutput) -> Void)?, onProgress: ((Double) -> Void)?,
                     isCancelled: @escaping () -> Bool) throws -> ScanOutput {
        guard scanLock.try() else {
            throw SensitiveDataScanError(message: "A scan is already running in this process")
        }
        defer { scanLock.unlock() }
        reportProgress = { onProgress?($0) }
        var options = Options()
        options.videoPath = videoPath
        options.customPhrases = customPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        options.faceCascadePath = faceCascadePath
        options.isTextRedacted = isTextRedacted
        options.demandMs = demandMs.map { Int(max($0, 0)) }
        return try runSensitiveDataScan(options, isCancelled: isCancelled, onPartialResult: onPartialResult)
    }

    /// Loads the text recognition models ahead of a scan.
    static func prewarm() {
        warmUpTextRecognition()
    }
}
