@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

extension SD {
    /// Scans chunks of one video: samples frames for change, reads text where it changed once it
    /// settles, and fills extra layers (faces, custom phrases) of chunks scanned before.
    final class Scanner {
        let options: Options
        let asset: AVURLAsset
        let videoFile: VideoFile
        let track: AVAssetTrack
        let grid: TileGrid
        let durationMs: Int
        let stats = ScanStats()
        let ocrQueue = OperationQueue()
        let faceQueue = OperationQueue()
        let readAdmission: ReadAdmission

        init(options: Options) throws {
            self.options = options
            let path = options.videoPath
            do {
                videoFile = try VideoFile(url: URL(fileURLWithPath: path))
            } catch {
                throw SensitiveDataScanError(message: "Cannot read " + path + ": " + "\(error)")
            }
            asset = videoFile.makeAsset()
            guard let track = asset.tracks(withMediaType: .video).first else {
                throw SensitiveDataScanError(message: "No video track in " + path)
            }
            self.track = track
            let size = track.naturalSize.applying(track.preferredTransform)
            let widthPx = Int(abs(size.width))
            let heightPx = Int(abs(size.height))
            grid = TileGrid(widthPx: widthPx, heightPx: heightPx, tilesX: (widthPx + 32 - 1) / 32, tilesY: (heightPx + 32 - 1) / 32)
            durationMs = Int(asset.duration.seconds * 1000)
            ocrQueue.maxConcurrentOperationCount = options.ocrWorkers
            ocrQueue.qualityOfService = .userInitiated
            faceQueue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
            faceQueue.qualityOfService = .userInitiated
            readAdmission = ReadAdmission(freeSlots: options.ocrWorkers * 2)
            // The file must be decodable at all.
            let probeAsset = videoFile.makeAsset()
            guard let probeTrack = probeAsset.tracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: probeAsset) else {
                throw SensitiveDataScanError(message: "Cannot read " + path)
            }
            reader.add(AVAssetReaderTrackOutput(track: probeTrack, outputSettings: nil))
            guard reader.startReading() else {
                throw SensitiveDataScanError(message: "Cannot decode " + path + ": " + (reader.error.map { SD.messageWithCodes($0) } ?? ""))
            }
            reader.cancelReading()
        }

        func makeChunkFrames(purpose: String, startMs: Int, endMs: Int) -> ChunkFrames {
            var makeReader: (() throws -> (AVAssetReader, AVAssetReaderTrackOutput))?
            if !videoFile.isPlaylist {
                makeReader = { [self] in try makeDecodingReader(startMs: startMs, endMs: endMs) }
            }
            var samples: VideoSampleReader?
            var failure: String?
            do {
                samples = try videoFile.makeSampleReader(fromMs: Double(startMs), toMs: Double(endMs))
            } catch {
                failure = String(describing: error)
            }
            return ChunkFrames(samples: samples, failure: failure, makeDecodingReader: makeReader, path: options.videoPath, purpose: purpose)
        }

        /// Asset reader that decodes the chunk to 4:2:0 video-range pixel buffers.
        private func makeDecodingReader(startMs: Int, endMs: Int) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let asset = videoFile.makeAsset()
            guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else {
                throw SD.fail("Cannot read " + options.videoPath)
            }
            reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
                                           end: CMTime(value: CMTimeValue(endMs), timescale: 1000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: UInt32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw SD.fail("Cannot decode " + options.videoPath + ": " + (reader.error.map { SD.messageWithCodes($0) } ?? ""))
            }
            return (reader, output)
        }

        // MARK: Reads

        /// Queues the text read of one band (and its face search) and returns whether it was queued.
        private func submitRead(luma: UnsafePointer<UInt8>, rowBytes: Int, band: CGRect, timeMs: Int, signatures: UnsafePointer<UInt8>,
                                chunk: Int, index: Int, reads: ChunkReads, layers: ChunkLayers, faces: ChunkFaceSearch) -> Bool {
            guard let image = SD.makeGrayImage(luma: luma, rowBytes: rowBytes, rect: band) else { return false }
            let frame = CGRect(x: 0, y: 0, width: Double(grid.widthPx), height: Double(grid.heightPx))
            let faceRegion = band.insetBy(dx: 0, dy: -384).intersection(frame)
            let faceImage = SD.makeGrayImage(luma: luma, rowBytes: rowBytes, rect: faceRegion)
            let isFullFrame = band.equalTo(frame)
            let firstTile = (Int(faceRegion.minY) / 32) * grid.tilesX
            let tileCount = grid.tilesX * grid.tilesY
            let endTile = min(((Int(faceRegion.maxY) + 32 - 1) / 32) * grid.tilesX, tileCount)
            let tileSignatures = Array(UnsafeBufferPointer(start: signatures + firstTile * 16, count: (endTile - firstTile) * 16))
            let stats = stats
            let readAdmission = readAdmission
            readAdmission.enter(chunk)
            reads.group.enter()
            autoreleasepool {
                let operation = BlockOperation {
                    autoreleasepool {
                        let start = CFAbsoluteTimeGetCurrent()
                        let (lines, findings) = SD.readText(image)
                        var hasPhotos = false
                        if let faceImage {
                            hasPhotos = !SD.photoRegions(in: faceImage.withLocalContrast(isDimmedOnly: true)).isEmpty
                        }
                        var phraseFindings: [(layer: String, findings: [Finding])] = []
                        phraseFindings.reserveCapacity(layers.phrases.count)
                        for phrase in layers.phrases {
                            phraseFindings.append((phrase.id, SD.readPhrase(image, lines: lines, phrase: phrase)))
                        }
                        let read = Observation(timeMs: timeMs, region: band, faceRegion: faceRegion, lines: lines, findings: findings,
                                               firstTile: firstTile, tileSignatures: tileSignatures)
                        reads.add(index, read: read, hasPhotos: hasPhotos, phraseFindings: phraseFindings)
                        let end = CFAbsoluteTimeGetCurrent()
                        stats.addRead(busySeconds: end - start, pixels: Int(band.width * band.height), isFullFrame: isFullFrame)
                        readAdmission.condition.lock()
                        readAdmission.freeSlots += 1
                        readAdmission.condition.broadcast()
                        readAdmission.condition.unlock()
                        reads.group.leave()
                    }
                }
                operation.queuePriority = readAdmission.priority(of: chunk)
                ocrQueue.addOperation(operation)
            }
            if layers.faceLayer != nil, let faceImage, SD.faceCascade != nil {
                reads.group.enter()
                autoreleasepool {
                    let observation = Observation(timeMs: timeMs, region: band, faceRegion: faceRegion, lines: [], findings: [],
                                                  firstTile: firstTile, tileSignatures: tileSignatures)
                    let grid = grid
                    faces.submit(faceImage, looksOfArea: { observation.looks(of: $0, in: grid) }, priority: readAdmission.priority(of: chunk),
                                 found: { found in
                                     reads.lock.lock()
                                     reads.faces[index] = found
                                     reads.lock.unlock()
                                     reads.group.leave()
                                 })
                }
            }
            return true
        }

        // MARK: Chunk scan

        /// Samples the chunk every `sampleMs`, records what changed per 32 px tile, measures vertical
        /// scrolling per stripe, and reads changed rows once they settle (or have been dirty too long).
        func scanChunk(_ chunk: Int, startMs: Int, endMs: Int, layers: ChunkLayers) throws -> ChunkScan {
            let reads = ChunkReads()
            let faces = ChunkFaceSearch(queue: faceQueue)
            var readCount = 0
            let lead = startMs > 0 ? 1000 : 0
            let frames = makeChunkFrames(purpose: "sensitive data scan", startMs: startMs - lead, endMs: endMs)
            let grid = grid
            let tileCount = grid.tilesX * grid.tilesY
            // Block means of tile rows below the frame's last block row are never computed; they stay zero.
            let reference = UnsafeMutablePointer<UInt8>.allocate(capacity: tileCount * 16)
            reference.initialize(repeating: 0, count: tileCount * 16)
            let current = UnsafeMutablePointer<UInt8>.allocate(capacity: tileCount * 16)
            current.initialize(repeating: 0, count: tileCount * 16)
            let readLooks = UnsafeMutablePointer<UInt8>.allocate(capacity: tileCount * 32)
            var lookCounts = [UInt8](repeating: 0, count: tileCount)
            let blockCount = grid.widthPx / 8 + 1
            let blockSums = UnsafeMutablePointer<UInt32>.allocate(capacity: blockCount)
            let blockStripes = UnsafeMutablePointer<Int>.allocate(capacity: blockCount)
            for b in 0..<blockCount { blockStripes[b] = grid.stripe(ofX: CGFloat(Double(b * 8))) }
            var previousProfiles = UnsafeMutablePointer<Int32>.allocate(capacity: grid.heightPx * 8)
            var currentProfiles = UnsafeMutablePointer<Int32>.allocate(capacity: grid.heightPx * 8)
            let coarsePrevious = UnsafeMutablePointer<Int32>.allocate(capacity: grid.heightPx / 4 + 1)
            let coarseCurrent = UnsafeMutablePointer<Int32>.allocate(capacity: grid.heightPx / 4 + 1)
            defer {
                reference.deallocate()
                current.deallocate()
                readLooks.deallocate()
                blockSums.deallocate()
                blockStripes.deallocate()
                previousProfiles.deallocate()
                currentProfiles.deallocate()
                coarsePrevious.deallocate()
                coarseCurrent.deallocate()
            }
            let tileStripes = (0..<tileCount).map { grid.stripe(ofX: CGFloat(Double(($0 % grid.tilesX) * 32 | 16))) }

            var sampledTimesMs: [Int] = []
            var stripeShifts = [Int16](repeating: 0, count: 8)
            var shiftSums = [Int](repeating: 0, count: 8)
            var isShiftUnknown = [Bool](repeating: false, count: 8)
            var dirtyLimitMs = [Int](repeating: options.maxDirtyMs, count: 8)
            var lastChangeMs = [Int](repeating: 0, count: grid.tilesY)
            var lastReadMs = [Int](repeating: Int.min / 2, count: grid.tilesY)
            var dirtySinceMs = [Int](repeating: -1, count: tileCount)
            var changedAtMs = [Int](repeating: Int.min / 2, count: tileCount)
            let threshold16 = options.changeThreshold * 16
            var nextSampleMs = startMs
            var samples: [ChangeSample] = []
            var sampledCount = 0
            var frameMs = Int.min / 2
            var lastFastScrollMs = Int.min / 2
            var lastShiftMs = Int.min / 2
            var previousChangedCount = 0
            var hasPrevious = false
            var previousMs = startMs
            var progressMs = startMs
            let sampleMs = options.sampleMs
            let settleMs = options.settleMs

            func isNeeded(_ ms: Double) -> Bool {
                let t = Int(ms.rounded(.up))
                guard startMs <= t else { return false }
                if t - lastFastScrollMs < 121 { return true }
                return nextSampleMs <= t && sampleMs <= t - frameMs
            }

            /// Whether the 16 block means of `a` match those of `b` once both tile means are removed.
            func isSameLook(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>) -> Bool {
                var sumA = 0, sumB = 0
                for j in 0..<16 {
                    sumA += Int(a[j])
                    sumB += Int(b[j])
                }
                for j in 0..<16 {
                    let d = (sumB - sumA) + Int(a[j]) * 16 - Int(b[j]) * 16
                    if threshold16 < d || d < -threshold16 { return false }
                }
                return true
            }

            /// Whether the tile looks again as it did at one of its last two reads.
            func wasReadLike(_ tile: Int) -> Bool {
                let count = Int(lookCounts[tile])
                for k in 0..<count where isSameLook(reference + tile * 16, readLooks + (tile * 2 + k) * 16) { return true }
                return false
            }

            /// Keeps the tile's look at its read (the last two different looks).
            func rememberReadLook(_ tile: Int) {
                let look = reference + tile * 16
                let latest = readLooks + tile * 32
                if lookCounts[tile] != 0, isSameLook(look, latest) { return }
                (latest + 16).update(from: latest, count: 16)
                latest.update(from: look, count: 16)
                lookCounts[tile] = min(lookCounts[tile] + 1, 2)
            }

            /// Reads the bands of the given rows from a frame at a time; `marksTilesRead` also marks their tiles clean and remembers their looks.
            func readRows(_ dueRows: [Bool], buffer: CVPixelBuffer, timeMs: Int, marksTilesRead: Bool) {
                let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                for band in SD.readingBands(dueRows: dueRows, grid: grid) {
                    let firstRow = Int(band.minY) / 32
                    let endRow = min((Int(band.maxY) + 32 - 1) / 32, grid.tilesY)
                    precondition(firstRow <= endRow)
                    for row in firstRow..<endRow {
                        lastReadMs[row] = timeMs
                        if marksTilesRead {
                            for tile in (row * grid.tilesX)..<((row + 1) * grid.tilesX) {
                                dirtySinceMs[tile] = -1
                                rememberReadLook(tile)
                            }
                        }
                    }
                    if submitRead(luma: luma, rowBytes: rowBytes, band: band, timeMs: timeMs, signatures: reference, chunk: chunk,
                                  index: readCount, reads: reads, layers: layers, faces: faces) {
                        readCount += 1
                    }
                }
            }

            /// Reads the rows whose dirty tiles are due: settled (still for `settleMs` and not read for
            /// `minRereadMs`), dirty for longer than their stripe's limit, or every dirty row when forced.
            func readDueTiles(buffer: CVPixelBuffer, timeMs: Int, isForced: Bool) {
                var dueRows = [Bool](repeating: false, count: grid.tilesY)
                var isAnyDue = false
                for tile in 0..<tileCount where dirtySinceMs[tile] >= 0 {
                    let row = tile / grid.tilesX
                    let isSettled = settleMs <= timeMs - lastChangeMs[row] && options.minRereadMs <= timeMs - lastReadMs[row]
                    let isStale = dirtyLimitMs[tileStripes[tile]] <= timeMs - dirtySinceMs[tile]
                    if isForced || isSettled || isStale {
                        dueRows[row] = true
                        isAnyDue = true
                    }
                }
                guard isAnyDue else { return }
                readRows(dueRows, buffer: buffer, timeMs: timeMs, marksTilesRead: true)
            }

            var processed: CVPixelBuffer?
            var pending = autoreleasepool { frames.next(isNeeded: isNeeded) }
            var isSwapDue = true
            frameLoop: while true {
                if isSwapDue { swap(&previousProfiles, &currentProfiles) }
                isSwapDue = false
                guard let first = pending else { break }
                var buffer = first.0
                var isEvent = first.isEvent
                var t = Int(first.1.rounded(.up))
                frameMs = t
                // Frames before the chunk: keep the last one as the previous frame.
                var leadIn: CVPixelBuffer?
                while t < startMs {
                    leadIn = buffer
                    guard let next = autoreleasepool(invoking: { frames.next(isNeeded: isNeeded) }) else {
                        pending = nil
                        break frameLoop
                    }
                    (buffer, isEvent) = (next.0, next.isEvent)
                    t = Int(next.1.rounded(.up))
                    frameMs = t
                }
                var previous = processed
                if let leadIn {
                    previous = leadIn
                    CVPixelBufferLockBaseAddress(leadIn, .readOnly)
                    let luma = CVPixelBufferGetBaseAddressOfPlane(leadIn, 0)!.assumingMemoryBound(to: UInt8.self)
                    SD.computeSignatures(luma: luma, rowBytes: CVPixelBufferGetBytesPerRowOfPlane(leadIn, 0), grid: grid, blockSums: blockSums,
                                         blockStripes: blockStripes, into: reference, stripeProfiles: previousProfiles)
                    hasPrevious = true
                    CVPixelBufferUnlockBaseAddress(leadIn, .readOnly)
                }
                var isWanted = t < endMs
                if isWanted {
                    if t < nextSampleMs {
                        isWanted = t - lastFastScrollMs < 121 || isEvent
                    } else {
                        repeat { nextSampleMs += sampleMs } while nextSampleMs <= t
                    }
                }
                if !isWanted {
                    processed = previous
                    pending = autoreleasepool { frames.next(isNeeded: isNeeded) }
                    continue
                }

                let elapsedMs = t - previousMs
                let stepMs = max(elapsedMs, 1)
                let sampledBefore = sampledCount
                sampledCount += 1
                sampledTimesMs.append(t)
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                SD.computeSignatures(luma: luma, rowBytes: rowBytes, grid: grid, blockSums: blockSums, blockStripes: blockStripes, into: current,
                                     stripeProfiles: currentProfiles)

                if !hasPrevious {
                    // First frame of the video: everything is new and read at once.
                    reference.update(from: current, count: tileCount * 16)
                    for row in 0..<grid.tilesY { lastChangeMs[row] = t }
                    for tile in 0..<tileCount { dirtySinceMs[tile] = t }
                    samples.append(ChangeSample(timeMs: t, isEverything: true, changedTiles: [], changedTileList: [],
                                                signatures: tileCount == 0 ? [] : Array(UnsafeBufferPointer(start: current, count: tileCount * 16)),
                                                stripeShiftsPx: []))
                    readDueTiles(buffer: buffer, timeMs: t, isForced: true)
                } else {
                    // Vertical scrolling per stripe, measured against the previous frame.
                    if let previous { CVPixelBufferLockBaseAddress(previous, .readOnly) }
                    let heightPx = grid.heightPx
                    for stripe in 0..<8 {
                        let last = stripeShifts[stripe]
                        let previousShift = last == Int16.min ? 0 : Int(last / 8)
                        let shift = SD.measureVerticalShift(previous: previousProfiles + stripe * heightPx, current: currentProfiles + stripe * heightPx,
                                                            height: heightPx, previousShift: previousShift, coarsePrevious: coarsePrevious,
                                                            coarseCurrent: coarseCurrent) { rows, shift in
                            SD.isShiftConfirmed(rows: rows, shift: shift, previous: previous, current: luma, rowBytes: rowBytes, stripe: stripe, grid: grid)
                        }
                        stripeShifts[stripe] = shift
                        if shift == Int16.min {
                            isShiftUnknown[stripe] = true
                        } else {
                            shiftSums[stripe] += Int(shift)
                        }
                        var limit = options.maxDirtyMs
                        if shift != Int16.min, abs(Int(shift)) > 7 {
                            let pixels = abs(Int(shift)) >> 3
                            if stepMs * 240 <= pixels * 1000 { lastFastScrollMs = t }
                            limit = min(max(heightPx * stepMs / pixels / 3, options.maxDirtyMs), options.maxScrollingDirtyMs)
                            lastShiftMs = t
                        }
                        dirtyLimitMs[stripe] = limit
                    }
                    if let previous { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }

                    // Tiles whose look changed against their last known look.
                    var changedTiles = [UInt64](repeating: 0, count: (tileCount + 63) / 64)
                    var changedTileList: [Int] = []
                    for tile in 0..<tileCount where !isSameLook(reference + tile * 16, current + tile * 16) {
                        changedTiles[tile >> 6] |= 1 << UInt64(tile & 63)
                        changedTileList.append(tile)
                    }

                    // A big change right after another: read what the previous frame showed before it went.
                    if previousChangedCount >= 8, let previous, elapsedMs < settleMs, previousMs - lastShiftMs >= 121, !changedTileList.isEmpty {
                        var dueRows = [Bool](repeating: false, count: grid.tilesY)
                        var isAnyDue = false
                        for tile in changedTileList where changedAtMs[tile] == previousMs {
                            let row = tile / grid.tilesX
                            if lastReadMs[row] < previousMs {
                                dueRows[row] = true
                                isAnyDue = true
                            }
                        }
                        if isAnyDue {
                            CVPixelBufferLockBaseAddress(previous, .readOnly)
                            readRows(dueRows, buffer: previous, timeMs: previousMs, marksTilesRead: false)
                            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
                        }
                    }

                    var signatures: [UInt8] = []
                    for tile in changedTileList {
                        (reference + tile * 16).update(from: current + tile * 16, count: 16)
                        signatures.append(contentsOf: UnsafeBufferPointer(start: current + tile * 16, count: 16))
                        changedAtMs[tile] = t
                    }
                    previousChangedCount = changedTileList.count
                    // When more than 30% of the tiles changed, the sample keeps only the bitset (no
                    // tile list, no looks); it is still not marked as a whole-frame change.
                    let isMostOfFrame = (tileCount * 3) / 10 < changedTileList.count
                    for tile in changedTileList {
                        if changedTileList.count < 9, wasReadLike(tile) {
                            if dirtySinceMs[tile] >= 0, lookCounts[tile] != 0 { dirtySinceMs[tile] = -1 }
                        } else {
                            lastChangeMs[tile / grid.tilesX] = t
                            if dirtySinceMs[tile] < 0 { dirtySinceMs[tile] = t }
                        }
                    }
                    if !changedTileList.isEmpty {
                        let shifts: [Int16] = (0..<8).map { stripe in
                            if isShiftUnknown[stripe] { return Int16.min }
                            let sum = shiftSums[stripe]
                            if sum < -0x8000 { return Int16.min }
                            return Int16(min(sum, 0x7fff))
                        }
                        shiftSums = [Int](repeating: 0, count: 8)
                        isShiftUnknown = [Bool](repeating: false, count: 8)
                        samples.append(ChangeSample(timeMs: t, isEverything: false, changedTiles: changedTiles,
                                                    changedTileList: isMostOfFrame ? [] : changedTileList,
                                                    signatures: isMostOfFrame ? nil : signatures, stripeShiftsPx: shifts))
                    }
                    if tileCount != 0, sampledBefore == 0 {
                        for tile in 0..<tileCount where dirtySinceMs[tile] < 0 { dirtySinceMs[tile] = t }
                    }
                    readDueTiles(buffer: buffer, timeMs: t, isForced: sampledBefore == 0)
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                hasPrevious = true
                processed = buffer
                previousMs = t
                if t - progressMs >= 1000 {
                    stats.addProgress(t - progressMs, totalMs: durationMs)
                    progressMs = t
                }
                pending = autoreleasepool { frames.next(isNeeded: isNeeded) }
                isSwapDue = true
            }

            if let failure = frames.failure { throw SD.fail("Decoding failed: " + failure) }
            if let failure = SD.failure { throw failure }
            if let last = processed, dirtySinceMs.contains(where: { $0 >= 0 }) {
                CVPixelBufferLockBaseAddress(last, .readOnly)
                readDueTiles(buffer: last, timeMs: previousMs, isForced: true)
                CVPixelBufferUnlockBaseAddress(last, .readOnly)
            }
            stats.addProgress(endMs - progressMs, totalMs: durationMs)
            stats.lock.lock()
            stats.changeSamples += samples.count
            stats.decodedFrames += frames.decodedCount
            stats.skippedFrames += frames.skippedCount
            stats.eventFrames += frames.eventCount
            stats.sampledFrames += sampledCount
            stats.lock.unlock()
            return reads.finish(chunk: chunk, readCount: readCount, samples: samples, sampledTimesMs: sampledTimesMs, layers: layers)
        }

        // MARK: Layers of a stored chunk

        /// Adds the face and phrase layers a stored chunk lacks, re-decoding only the frames of the
        /// reads that need them.
        func fillLayers(_ evidence: ChunkEvidence, startMs: Int, endMs: Int, layers: ChunkLayers) throws -> ChunkScan {
            let readTotal = evidence.reads.count
            var facesByRead = [[Finding]](repeating: [], count: readTotal)
            var phraseFindings: [String: [Int: [Finding]]] = [:]
            var readsByTime: [Int: [Int]] = [:]
            for (index, read) in evidence.reads.enumerated() {
                let needsFaces = layers.faceLayer != nil && evidence.readHasPhotos[index]
                var needsPhrase = false
                search: for phrase in layers.phrases {
                    for line in read.lines {
                        for key in phrase.candidateKeys where line.key.contains(key) {
                            needsPhrase = true
                            break search
                        }
                    }
                }
                if needsPhrase || needsFaces { readsByTime[read.timeMs, default: []].append(index) }
            }
            if !readsByTime.isEmpty {
                let cache = FaceSearchCache()
                let frames = makeChunkFrames(purpose: "sensitive data layers", startMs: max(startMs - 2, 0), endMs: endMs + 2)
                var remaining = readsByTime.count
                while remaining > 0 {
                    let next = autoreleasepool {
                        frames.next(isNeeded: { ms in readsByTime[Int(ms.rounded(.up))] != nil })
                    }
                    guard let next else {
                        if let failure = frames.failure { throw SD.fail("Decoding failed: " + failure) }
            if let failure = SD.failure { throw failure }
                        throw SD.fail("\(remaining)" + " read frames of chunk " + "\(evidence.chunkIndex)" + " were not found again")
                    }
                    let buffer = next.0
                    guard let indices = readsByTime[Int(next.1.rounded(.up))] else { continue }
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                    for index in indices.sorted() {
                        let read = evidence.reads[index]
                        if layers.faceLayer != nil, evidence.readHasPhotos[index], SD.faceCascade != nil,
                           let image = SD.makeGrayImage(luma: luma, rowBytes: rowBytes, rect: read.faceRegion) {
                            let grid = grid
                            facesByRead[index] = SD.findFaces(in: image, cache: cache, looksOfArea: { read.looks(of: $0, in: grid) })
                        }
                        var due: [PhraseLayer] = []
                        for phrase in layers.phrases {
                            var isCandidate = false
                            search: for line in read.lines {
                                for key in phrase.candidateKeys where line.key.contains(key) {
                                    isCandidate = true
                                    break search
                                }
                            }
                            if isCandidate { due.append(phrase) }
                        }
                        if !due.isEmpty, let image = SD.makeGrayImage(luma: luma, rowBytes: rowBytes, rect: read.region) {
                            for phrase in due {
                                let found = SD.readPhrase(image, lines: read.lines, phrase: phrase)
                                if !found.isEmpty { phraseFindings[phrase.id, default: [:]][index] = found }
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    remaining -= 1
                }
                if let failure = frames.failure { throw SD.fail("Decoding failed: " + failure) }
            if let failure = SD.failure { throw failure }
                stats.lock.lock()
                stats.layerDecodedFrames += frames.decodedCount
                stats.lock.unlock()
            }
            let faces = layers.faceLayer != nil ? ChunkFaces(facesByRead: facesByRead) : nil
            let phrases = Dictionary(uniqueKeysWithValues: layers.phrases.map { ($0.id, ChunkPhrase(findingsByRead: phraseFindings[$0.id] ?? [:])) })
            return ChunkScan(evidence: evidence, faces: faces, phrases: phrases)
        }
    }

    /// Error text with its domain and code.
    static func messageWithCodes(_ error: Error) -> String {
        // Exact formatting of decoder errors with their codes; the localized description is used.
        let ns = error as NSError
        return ns.localizedDescription + " (" + ns.domain + " " + "\(ns.code)" + ")"
    }
}
