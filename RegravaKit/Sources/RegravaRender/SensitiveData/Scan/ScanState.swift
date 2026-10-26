import CoreGraphics
import Foundation

extension SD {
    /// Counters of one scan, shared by all chunks and reads.
    final class ScanStats {
        let lock = NSLock()
        var decodedFrames = 0
        var skippedFrames = 0
        var eventFrames = 0
        var sampledFrames = 0
        var changeSamples = 0
        var ocrJobs = 0
        var ocrFullFrameJobs = 0
        var ocrPixels = 0
        var ocrBusySeconds = 0.0
        var computedChunks = 0
        var storedChunks = 0
        var filledChunks = 0
        var layerDecodedFrames = 0
        var processedMs = 0
        var reportedProgressPercent = -1

        func addRead(busySeconds: Double, pixels: Int, isFullFrame: Bool) {
            lock.lock()
            ocrJobs += 1
            if isFullFrame { ocrFullFrameJobs += 1 }
            ocrPixels += pixels
            ocrBusySeconds = busySeconds + ocrBusySeconds
            lock.unlock()
        }

        /// Adds scanned video time and reports progress (whole percents, only when it grows).
        func addProgress(_ ms: Int, totalMs: Int) {
            lock.lock()
            processedMs += ms
            let total = max(totalMs, 1)
            let percent = min((processedMs * 100) / total, 100)
            guard reportedProgressPercent < percent else {
                lock.unlock()
                return
            }
            reportedProgressPercent = percent
            lock.unlock()
            SD.printJSON(["type": "progress", "progress": Double(percent) / 100.0])
        }
    }

    /// Bounds how many reads are queued at once and lets chunks earlier in the scan order go first.
    final class ReadAdmission {
        let condition = NSCondition()
        var freeSlots: Int
        var waitingByChunk: [Int: Int] = [:]
        var activeChunks: [Int: Int] = [:]
        var rankByChunk: [Int: Int] = [:]

        init(freeSlots: Int) { self.freeSlots = freeSlots }

        /// Sets the scan order: the chunk at position i gets rank i (unranked chunks rank as their index).
        func rank(by order: [Int]) {
            condition.lock()
            let pairs = order.enumerated().map { ($0.element, $0.offset) }
            rankByChunk = Dictionary(uniqueKeysWithValues: pairs)
            condition.unlock()
        }

        private func rankOf(_ chunk: Int) -> Int { rankByChunk[chunk] ?? chunk }

        /// Runs `body` while the chunk counts as being scanned.
        func scanning<A>(_ chunk: Int, _ body: () throws -> A) rethrows -> A {
            condition.lock()
            activeChunks[chunk, default: 0] += 1
            condition.unlock()
            defer {
                condition.lock()
                activeChunks[chunk]! -= 1
                if let n = activeChunks[chunk], n == 0 { activeChunks.removeValue(forKey: chunk) }
                condition.broadcast()
                condition.unlock()
            }
            return try body()
        }

        /// Takes a read slot, waiting while none is free or a better-ranked chunk is waiting for one.
        func enter(_ chunk: Int) {
            condition.lock()
            waitingByChunk[chunk, default: 0] += 1
            let mine = rankOf(chunk)
            while true {
                if freeSlots != 0 {
                    var isAhead = false
                    for other in waitingByChunk.keys where rankOf(other) < mine {
                        isAhead = true
                        break
                    }
                    if !isAhead {
                        waitingByChunk[chunk]! -= 1
                        if let n = waitingByChunk[chunk], n == 0 { waitingByChunk.removeValue(forKey: chunk) }
                        freeSlots -= 1
                        condition.broadcast()
                        condition.unlock()
                        return
                    }
                }
                condition.wait()
            }
        }

        /// Queue priority of a chunk's reads: highest when no better-ranked chunk is being scanned.
        func priority(of chunk: Int) -> Operation.QueuePriority {
            condition.lock()
            let mine = rankOf(chunk)
            var ahead: [Int] = []
            for other in activeChunks.keys where rankOf(other) < mine { ahead.append(other) }
            condition.unlock()
            switch ahead.count {
            case 0: return .veryHigh
            case 1: return .high
            case 2: return .normal
            case 3: return .low
            default: return .veryLow
            }
        }
    }

    /// The reads of one chunk as they finish, in submission order.
    final class ChunkReads {
        let group = DispatchGroup()
        let lock = NSLock()
        var reads: [Int: (read: Observation, hasPhotos: Bool)] = [:]
        var faces: [Int: [Finding]] = [:]
        var phrases: [String: [Int: [Finding]]] = [:]

        func add(_ index: Int, read: Observation, hasPhotos: Bool, phraseFindings: [(layer: String, findings: [Finding])]) {
            lock.lock()
            reads[index] = (read, hasPhotos)
            for (layer, findings) in phraseFindings where !findings.isEmpty {
                phrases[layer, default: [:]][index] = findings
            }
            lock.unlock()
        }

        /// Waits for every queued read and builds the chunk's evidence and layers.
        func finish(chunk: Int, readCount: Int, samples: [ChangeSample], sampledTimesMs: [Int], layers: ChunkLayers) -> ChunkScan {
            group.wait()
            var done: [(read: Observation, hasPhotos: Bool)] = []
            for i in 0..<readCount {
                guard let r = reads[i] else { break }
                done.append(r)
            }
            let observations = done.map(\.read)
            let hasPhotos = done.map(\.hasPhotos)
            var chunkFaces: ChunkFaces?
            if layers.faceLayer != nil {
                chunkFaces = ChunkFaces(facesByRead: (0..<readCount).map { faces[$0] ?? [] })
            }
            let chunkPhrases = Dictionary(uniqueKeysWithValues: layers.phrases.map { ($0.id, ChunkPhrase(findingsByRead: phrases[$0.id] ?? [:])) })
            let evidence = ChunkEvidence(chunkIndex: chunk, changeSamples: samples, sampledTimesMs: sampledTimesMs, reads: observations, readHasPhotos: hasPhotos)
            return ChunkScan(evidence: evidence, faces: chunkFaces, phrases: chunkPhrases)
        }
    }
}
