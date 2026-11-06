import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// A flag read and set from any thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// The last mattes used, by frame: at most `capacity`, the least recently used leaving first.
final class MatteMemory: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var entries: [Int: (matte: [UInt8], lastUse: Int)] = [:]
    private var clock = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func get(_ frame: Int) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[frame] else { return nil }
        clock += 1
        entries[frame] = (entry.matte, clock)
        return entry.matte
    }

    func set(_ frame: Int, _ matte: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        entries[frame] = (matte, clock)
        while entries.count > capacity {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            entries[oldest.key] = nil
        }
    }

    func contains(_ frame: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[frame] != nil
    }
}

/// Mattes a webcam video's frames in parallel lanes, each lane decoding its own stretch of frames
/// and matting them one by one with its own matter.
final class PersonMatteSweep: @unchecked Sendable {
    let videoURL: URL
    let frameTimes: [CMTime]
    let window: CGRect
    let laneCount: Int
    private let workers: [FrameMatter]

    init(videoURL: URL, frameTimes: [CMTime], window: CGRect, laneCount: Int) {
        self.videoURL = videoURL
        self.frameTimes = frameTimes
        self.window = window
        self.laneCount = laneCount
        workers = (0..<laneCount).map { _ in FrameMatter(window: window) }
    }

    /// The exact index of a decoded frame's time.
    static func frameIndex(of time: CMTime, in times: [CMTime]) -> Int? {
        var low = 0, high = times.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] == time { return mid }
            if times[mid] < time { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// One lane per segment, all at once. `onFrame(lane, frame, matte, guide)`; the first error stops the call.
    func runSegments(_ segments: [Range<Int>], wantsGuide: Bool, shouldYield: @escaping () -> Bool,
                     onFrame: @escaping (Int, Int, [UInt8], [UInt8]?) throws -> Void, isCancelled: @escaping () -> Bool) throws {
        precondition(segments.count <= laneCount)
        let failureLock = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: segments.count) { lane in
            do {
                try runLane(frames: segments[lane], worker: workers[lane], wantsGuide: wantsGuide, shouldYield: shouldYield,
                            onFrame: { try onFrame(lane, $0, $1, $2) }, isCancelled: isCancelled)
            } catch {
                failureLock.lock()
                if failure == nil { failure = error }
                failureLock.unlock()
            }
        }
        failureLock.lock()
        let error = failure
        failureLock.unlock()
        if let error { throw error }
    }

    private func runLane(frames: Range<Int>, worker: FrameMatter, wantsGuide: Bool, shouldYield: () -> Bool,
                         onFrame: (Int, [UInt8], [UInt8]?) throws -> Void, isCancelled: () -> Bool) throws {
        let end: CMTime? = frames.upperBound < frameTimes.count ? frameTimes[frames.upperBound] : nil
        let reader = try CameraFrames.DecodedFrames(videoURL: videoURL, from: frameTimes[frames.lowerBound], to: end)
        defer { reader.cancel() }
        var done: Set<Int> = []
        if !isCancelled() {
            while let (frame, time) = try reader.next() {
                if let index = Self.frameIndex(of: time, in: frameTimes), frames.contains(index), !done.contains(index) {
                    // Live matting (the shown frame) goes first.
                    while shouldYield() {
                        if isCancelled() { break }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    let matte = try worker.matte(frame)
                    let guide = wantsGuide ? FrameMatter.guide(frame, window: window) : nil
                    try onFrame(index, matte, guide)
                    done.insert(index)
                }
                if isCancelled() { break }
            }
        }
        if isCancelled() { return }
        guard done.count != frames.count else { return }
        let missing = frames.filter { !done.contains($0) }
        throw MatteChunkError.message("The decoder never showed frames " + missing.map(String.init).joined(separator: ", "))
    }
}

/// What the drawing side tells a sweep: the frame shown last, and whether a frame is being
/// matted live right now (the sweep yields to it).
final class MatteDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var frame = 0
    private var live = 0

    var demandedFrame: Int {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    var isLiveBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return live > 0
    }

    func demand(_ frame: Int) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func beginLive() {
        lock.lock()
        live += 1
        lock.unlock()
    }

    func endLive() {
        lock.lock()
        live -= 1
        lock.unlock()
    }
}

/// A webcam's person mattes for drawing: from memory, else from the project's cache, else from
/// the network (Vision) at once. A sweep fills the cache in the background, nearest the shown
/// frame first, with the mattes filtered over time and stored as H.264. With
/// `waitsForStoredMattes` (an export) a frame waits for its stored matte instead, so the frames
/// are the same whatever the cache held before.
public final class CameraMatting: @unchecked Sendable {
    /// Mattes kept in memory.
    static let memoryCapacity = 180
    /// Lanes a sweep asks for.
    static let sweepLaneLimit = 3
    /// Chunks each lane of a sweep takes in a row.
    static let chunksPerLane = 2

    public let videoURL: URL
    let frameTimes: [CMTime]
    let frameTimesMs: [Double]
    /// The person window (0…1 of the frame, from the top) the mattes cover.
    public let window: CGRect
    let cache: MatteCache
    public let waitsForStoredMattes: Bool
    let canSweep: Bool
    private let memory = MatteMemory(capacity: CameraMatting.memoryCapacity)
    private let matter: FrameMatter
    private let stopped = LockedFlag()
    private let sweepFailed = LockedFlag()
    private let demand = MatteDemand()
    private let lock = NSLock()
    private(set) var mattesComputed = 0
    private(set) var mattesFromMemory = 0
    private(set) var mattesFromDisk = 0
    private var progress: (stored: Int, chunks: Int)?
    private var stopListening: (@Sendable () -> Void)?
    private var sweepThread: Thread?

    /// `cacheRoot` defaults to the project's `cache/camera-matte/`. Reads the frame times and finds
    /// the person window (estimated once per video, then kept).
    init(videoURL: URL, frameCount: Int? = nil, cacheRoot: URL? = nil, waitsForStoredMattes: Bool) throws {
        self.videoURL = videoURL
        self.waitsForStoredMattes = waitsForStoredMattes
        frameTimes = try CameraFrames.frameTimes(videoURL: videoURL)
        frameTimesMs = frameTimes.map { $0.seconds * 1000 }
        let count = frameCount ?? frameTimes.count
        canSweep = frameTimes.count == count
        if !canSweep {
            FileHandle.standardError.write(Data(("[CameraMatting] " + videoURL.path + ": " + String(count) + " frames expected, the video has " + String(frameTimes.count) + "; mattes are not cached\n").utf8))
        }
        let root = cacheRoot ?? MatteCache.root(forVideoAt: videoURL.path)
        window = try PersonWindow.window(videoURL: videoURL, frameTimes: frameTimes, model: FrameMatter.model, cacheRoot: root)
        let videoKey = MatteCache.videoKey(forVideoAt: videoURL.path)
        cache = try MatteCache.open(root: root, videoKey: videoKey, identity: MatteCache.identity(videoKey: videoKey, model: FrameMatter.model, window: window), frameCount: count)
        matter = FrameMatter(window: window)
    }

    deinit {
        stop()
    }

    // MARK: Shared instances

    private struct Weak {
        weak var matting: CameraMatting?
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Weak] = [:]
    nonisolated(unsafe) private static var openingLocks: [String: NSLock] = [:]

    /// The open mattes of `videoURL` (one for the editor, one for exports), opened and swept on
    /// first use. Kept while anyone holds them.
    public static func open(videoURL: URL, waitsForStoredMattes: Bool) throws -> CameraMatting {
        let key = videoURL.standardizedFileURL.path + (waitsForStoredMattes ? "|export" : "|editor")
        registryLock.lock()
        if let existing = registry[key]?.matting {
            registryLock.unlock()
            return existing
        }
        let opening = openingLocks[key] ?? NSLock()
        openingLocks[key] = opening
        registryLock.unlock()
        // One opening per video; the others wait for it.
        opening.lock()
        defer { opening.unlock() }
        registryLock.lock()
        if let existing = registry[key]?.matting {
            registryLock.unlock()
            return existing
        }
        registryLock.unlock()
        let matting = try CameraMatting(videoURL: videoURL, waitsForStoredMattes: waitsForStoredMattes)
        matting.startSweep { _, _ in }
        registryLock.lock()
        registry = registry.filter { $0.value.matting != nil }
        registry[key] = Weak(matting: matting)
        registryLock.unlock()
        return matting
    }

    /// Loads the matte model once and lets it go, so the first camera cutout does not wait for
    /// it: the first load on a Mac compiles the model, later loads are quick. Called early after
    /// launch. Whether it loaded.
    @discardableResult
    public static func prewarm() -> Bool {
        FrameMatter(window: PersonWindow.wholeFrame).isLoaded
    }

    /// Stops the sweep; frames waiting for a stored matte give up.
    public func stop() {
        stopped.set()
        lock.lock()
        let listener = stopListening
        stopListening = nil
        lock.unlock()
        listener?()
    }

    /// Chunks stored of all, as last reported by the sweep.
    public var matteProgress: (stored: Int, chunks: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    /// The frame shown at `ms` (presentation time): the last one at or before it, else the first.
    public func frameIndex(atMs ms: Double) -> Int? {
        guard !frameTimesMs.isEmpty else { return nil }
        var low = 0, high = frameTimesMs.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if frameTimesMs[mid] <= ms + 0.5 { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return max(found, 0)
    }

    /// Where the sweep looks first: the frame drawn last.
    func demand(_ frame: Int) {
        demand.demand(frame)
    }

    private func count(_ counter: ReferenceWritableKeyPath<CameraMatting, Int>) {
        lock.lock()
        self[keyPath: counter] += 1
        lock.unlock()
    }

    /// The matte of frame `index` (`frame` is its picture), as stored or straight from the network.
    func matte(of index: Int, frame: CIImage) throws -> [UInt8] {
        if let remembered = memory.get(index) {
            count(\.mattesFromMemory)
            return remembered
        }
        if canSweep {
            let chunk = index / MatteCache.chunkFrameCount
            if waitsForStoredMattes {
                let stopped = self.stopped, sweepFailed = self.sweepFailed
                _ = cache.waitUntilStored(chunk) { stopped.isSet || sweepFailed.isSet }
                if stopped.isSet { throw CancellationError() }
            }
            if cache.isStored(chunk), let mattes = try? cache.read(chunk) {
                let start = chunk * MatteCache.chunkFrameCount
                for (offset, matte) in mattes.enumerated() { memory.set(start + offset, matte) }
                count(\.mattesFromDisk)
                let offset = index % MatteCache.chunkFrameCount
                if offset < mattes.count { return mattes[offset] }
            }
        }
        demand.beginLive()
        defer { demand.endLive() }
        let matte = try matter.matte(frame)
        memory.set(index, matte)
        count(\.mattesComputed)
        return matte
    }

    // MARK: Sweep

    /// Reports `onProgress(stored, chunks)` now and after every stored chunk, and fills the cache
    /// on a thread of its own until it is complete or stopped.
    func startSweep(onProgress: @escaping @Sendable (Int, Int) -> Void) {
        let cache = self.cache
        let report: @Sendable (Int, Int) -> Void = { [weak self] stored, chunks in
            if let self {
                self.lock.lock()
                self.progress = (stored, chunks)
                self.lock.unlock()
            }
            onProgress(stored, chunks)
        }
        report(cache.storedChunkCount, cache.chunkCount)
        guard canSweep, !cache.isComplete else {
            if cache.isComplete { cache.deleteOtherIdentities() }
            return
        }
        let remove = cache.addStoredListener { [weak cache] in
            guard let cache else { return }
            report(cache.storedChunkCount, cache.chunkCount)
        }
        lock.lock()
        stopListening = remove
        lock.unlock()
        // The thread holds the parts it needs, not the mattes object, so dropping that stops it.
        let sweep = Sweep(videoURL: videoURL, frameTimes: frameTimes, window: window, cache: cache, memory: memory, demand: demand, stopped: stopped)
        let waits = waitsForStoredMattes, demand = self.demand, stopped = self.stopped, sweepFailed = self.sweepFailed
        let thread = Thread {
            do {
                try sweep.run(isLiveBusy: { !waits && demand.isLiveBusy })
            } catch {
                if stopped.isSet { return }
                sweepFailed.set()
                FileHandle.standardError.write(Data(("[CameraMatting] sweep stopped: " + String(describing: error) + "\n").utf8))
            }
        }
        thread.name = "camera-matting.sweep"
        thread.qualityOfService = .utility
        sweepThread = thread
        thread.start()
    }

    /// Runs of up to `chunksPerLane` adjacent chunks, at most `laneCount` of them, in claim order
    /// (each chunk joins the first run it extends). With no more chunks than lanes, one chunk each.
    static func runsOfAdjacentChunks(_ chunks: [Int], laneCount: Int, chunksPerLane: Int) -> [[Int]] {
        let perLane = chunks.count <= laneCount ? 1 : chunksPerLane
        var runs: [[Int]] = []
        for chunk in chunks {
            var joined = false
            for index in runs.indices where runs[index].count < perLane {
                if runs[index][0] - 1 == chunk {
                    runs[index].insert(chunk, at: 0)
                    joined = true
                    break
                }
                if runs[index][runs[index].count - 1] + 1 == chunk {
                    runs[index].append(chunk)
                    joined = true
                    break
                }
            }
            if !joined, runs.count < laneCount { runs.append([chunk]) }
        }
        return runs
    }

    /// The sweep's loop: while chunks are missing, take up to three decode lanes, claim twice as
    /// many chunks as lanes nearest the shown frame, matte them (each run of chunks on a lane),
    /// filter and store them.
    final class Sweep: @unchecked Sendable {
        let videoURL: URL
        let frameTimes: [CMTime]
        let window: CGRect
        let cache: MatteCache
        let memory: MatteMemory
        let demand: MatteDemand
        let stopped: LockedFlag

        init(videoURL: URL, frameTimes: [CMTime], window: CGRect, cache: MatteCache, memory: MatteMemory, demand: MatteDemand, stopped: LockedFlag) {
            self.videoURL = videoURL
            self.frameTimes = frameTimes
            self.window = window
            self.cache = cache
            self.memory = memory
            self.demand = demand
            self.stopped = stopped
        }

        func run(isLiveBusy: @escaping () -> Bool) throws {
            let cache = self.cache, memory = self.memory, stopped = self.stopped
            var sweep: PersonMatteSweep?
            while !stopped.isSet {
                if cache.isComplete {
                    cache.deleteOtherIdentities()
                    return
                }
                let lanes = SD.DecodeLanes.shared.acquire(upTo: CameraMatting.sweepLaneLimit, isCancelled: { stopped.isSet })
                guard !lanes.isEmpty else { return }
                defer { lanes.forEach { $0.release() } }
                let claimed = cache.claimMissing(near: demand.demandedFrame / MatteCache.chunkFrameCount, count: lanes.count * 2)
                let runs = CameraMatting.runsOfAdjacentChunks(claimed, laneCount: lanes.count, chunksPerLane: CameraMatting.chunksPerLane)
                let chunks = runs.flatMap { $0 }
                cache.release(claimed.filter { !chunks.contains($0) })
                if chunks.isEmpty {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                var written: Set<Int> = []
                defer { cache.release(chunks.filter { !written.contains($0) }) }
                if sweep == nil {
                    sweep = PersonMatteSweep(videoURL: videoURL, frameTimes: frameTimes, window: window, laneCount: CameraMatting.sweepLaneLimit)
                }
                guard let sweep else { return }
                let frameCount = cache.frameCount
                // Each run with two frames of context on either side for the time filter.
                let segments = runs.map { run -> Range<Int> in
                    let start = run[0] * MatteCache.chunkFrameCount
                    let end = min((run[run.count - 1] + 1) * MatteCache.chunkFrameCount, frameCount)
                    return max(start - 2, 0)..<min(end + 2, frameCount)
                }
                let flickers = runs.map { run in
                    run.map { chunk in
                        ChunkFlicker(start: chunk * MatteCache.chunkFrameCount, end: min((chunk + 1) * MatteCache.chunkFrameCount, frameCount), frameCount: frameCount)
                    }
                }
                try sweep.runSegments(segments, wantsGuide: true, shouldYield: isLiveBusy, onFrame: { lane, frame, matte, guide in
                    for flicker in flickers[lane] { flicker.add(frame, matte: matte, guide: guide ?? []) }
                }, isCancelled: { stopped.isSet })
                if stopped.isSet { return }
                for (chunk, flicker) in zip(chunks, flickers.flatMap { $0 }) {
                    guard let mattes = flicker.finish() else { throw MatteChunkError.message("chunk " + String(chunk) + " is missing frames") }
                    try cache.write(chunk, mattes: mattes)
                    written.insert(chunk)
                    // Frames remembered with the network's matte now take the stored one.
                    let frames = cache.frames(ofChunk: chunk)
                    if frames.contains(where: { memory.contains($0) }) {
                        let stored = try cache.read(chunk)
                        for (offset, matte) in stored.enumerated() where memory.contains(frames.lowerBound + offset) {
                            memory.set(frames.lowerBound + offset, matte)
                        }
                    }
                }
            }
        }
    }
}
