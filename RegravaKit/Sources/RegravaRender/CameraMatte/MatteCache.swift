import CryptoKit
import Foundation
import RegravaCore

/// A camera's stored mattes: chunks of `chunkFrameCount` frames, each an H.264 movie
/// (`chunk-000012.mp4`) in `<root>/<identity>/`, with a `manifest.json` naming the video they
/// belong to. Chunks are claimed by whoever computes them, so two sweeps never do one twice.
final class MatteCache: @unchecked Sendable {
    static let chunkFrameCount = 30
    static let formatVersion = 1
    /// Size of a stored matte.
    static let matteWidth = 1024
    static let matteHeight = 576

    struct Manifest: Codable {
        var formatVersion: Int
        var videoKey: String
        var frameCount: Int
        var chunkFrameCount: Int
    }

    let directory: URL
    let videoKey: String
    let frameCount: Int
    private let lock = NSCondition()
    private var stored: Set<Int>
    private var claimed: Set<Int> = []
    private var storedListeners: [Int: @Sendable () -> Void] = [:]
    private var nextListenerId = 0

    // MARK: Where mattes live

    /// `<bundle>.regrava/cache/camera-matte/` for a video inside a project bundle, else
    /// `<temporary directory>/camera-matte/`.
    static func root(forVideoAt videoPath: String, bundleExtension: String = ProjectStore.fileExtension) -> URL {
        let components = URL(fileURLWithPath: videoPath).standardizedFileURL.pathComponents
        for (index, component) in components.enumerated() where component.hasSuffix("." + bundleExtension) {
            let bundle = NSString.path(withComponents: Array(components[...index]))
            return URL(fileURLWithPath: bundle, isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("camera-matte", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("camera-matte", isDirectory: true)
    }

    /// "<standardized path>|<size or -1>|<whole seconds of the modification date or 0>".
    static func videoKey(forVideoAt videoPath: String) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: videoPath)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return URL(fileURLWithPath: videoPath).standardizedFileURL.path + "|" + String(size) + "|" + String(Int(modified))
    }

    /// "matte-" and a short hash of the video, the model and the person window.
    static func identity(videoKey: String, model: String, window: CGRect) -> String {
        let rect = [window.minX, window.minY, window.width, window.height].map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
        return "matte-" + shortHash(String(formatVersion) + "|" + videoKey + "|" + model + "|" + rect)
    }

    /// The first 10 bytes of the text's SHA-256, in hex.
    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Opening

    private struct WeakCache {
        weak var cache: MatteCache?
    }

    private static let openedLock = NSLock()
    nonisolated(unsafe) private static var opened: [String: WeakCache] = [:]

    /// The cache of `identity` under `root`, shared while anyone holds it.
    static func open(root: URL, videoKey: String, identity: String, frameCount: Int) throws -> MatteCache {
        openedLock.lock()
        defer { openedLock.unlock() }
        let path = root.appendingPathComponent(identity, isDirectory: true).standardizedFileURL.path
        if let existing = opened[path]?.cache, existing.videoKey == videoKey, existing.frameCount == frameCount {
            return existing
        }
        let cache = try MatteCache(root: root, videoKey: videoKey, identity: identity, frameCount: frameCount)
        opened = opened.filter { $0.value.cache != nil }
        opened[path] = WeakCache(cache: cache)
        return cache
    }

    /// Starts over when the manifest is for another video, frame count or format.
    init(root: URL, videoKey: String, identity: String, frameCount: Int) throws {
        self.videoKey = videoKey
        self.frameCount = frameCount
        directory = root.appendingPathComponent(identity, isDirectory: true)
        let fileManager = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL) {
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            let isCurrent = manifest.map { $0.formatVersion == Self.formatVersion && $0.videoKey == videoKey && $0.frameCount == frameCount && $0.chunkFrameCount == Self.chunkFrameCount } ?? false
            if !isCurrent { try? fileManager.removeItem(at: directory) }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        if !fileManager.fileExists(atPath: manifestURL.path) {
            let manifest = Manifest(formatVersion: Self.formatVersion, videoKey: videoKey, frameCount: frameCount, chunkFrameCount: Self.chunkFrameCount)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var chunks: [Int] = []
        for name in names where name.hasPrefix("chunk-") && name.hasSuffix(".mp4") {
            if let chunk = Int(name.dropFirst("chunk-".count).dropLast(".mp4".count)) { chunks.append(chunk) }
        }
        stored = Set(chunks)
    }

    // MARK: Chunks

    var chunkCount: Int { (frameCount + Self.chunkFrameCount - 1) / Self.chunkFrameCount }

    func chunkIndex(ofFrame frame: Int) -> Int { frame / Self.chunkFrameCount }

    func frames(ofChunk chunk: Int) -> Range<Int> {
        let start = chunk * Self.chunkFrameCount
        return start..<min(start + Self.chunkFrameCount, frameCount)
    }

    func url(ofChunk chunk: Int) -> URL {
        directory.appendingPathComponent("chunk-" + String(format: "%06d", chunk) + ".mp4")
    }

    var storedChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }

    var isComplete: Bool {
        lock.lock()
        let count = stored.count
        lock.unlock()
        return count >= chunkCount
    }

    func isStored(_ chunk: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored.contains(chunk)
    }

    /// Up to `count` chunks nobody stored or claimed, nearest `near` first (those before it count
    /// twice their distance), claimed for the caller.
    func claimMissing(near: Int, count: Int) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        var missing: [Int] = []
        for chunk in 0..<chunkCount where !stored.contains(chunk) && !claimed.contains(chunk) { missing.append(chunk) }
        func priority(_ chunk: Int) -> Int { chunk >= near ? chunk - near : (near - chunk) * 2 }
        // Stable: equal priorities keep chunk order.
        let sorted = missing.enumerated().sorted { a, b in
            let pa = priority(a.element), pb = priority(b.element)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        let taken = Array(sorted.prefix(max(count, 0)))
        claimed.formUnion(taken)
        return taken
    }

    /// Gives back claims without storing them.
    func release(_ chunks: [Int]) {
        lock.lock()
        for chunk in chunks { claimed.remove(chunk) }
        lock.unlock()
    }

    /// Stores a chunk's mattes (in frame order) and tells the listeners.
    func write(_ chunk: Int, mattes: [[UInt8]]) throws {
        try MatteChunkWriter.write(mattes: mattes, width: Self.matteWidth, height: Self.matteHeight, framesPerSecond: Self.chunkFrameCount, to: url(ofChunk: chunk))
        lock.lock()
        stored.insert(chunk)
        claimed.remove(chunk)
        let listeners = Array(storedListeners.values)
        lock.broadcast()
        lock.unlock()
        for listener in listeners { listener() }
    }

    func read(_ chunk: Int) throws -> [[UInt8]] {
        let mattes = try MatteChunkReader.read(url(ofChunk: chunk), width: Self.matteWidth, height: Self.matteHeight)
        let expected = frames(ofChunk: chunk).count
        guard mattes.count == expected else {
            throw MatteChunkError.message("chunk " + String(chunk) + " holds " + String(mattes.count) + " mattes")
        }
        return mattes
    }

    /// Blocks until `chunk` is stored (true) or `shouldStop` says so (false), checking every 0.1 s.
    func waitUntilStored(_ chunk: Int, shouldStop: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while !stored.contains(chunk) {
            if shouldStop() { return false }
            lock.wait(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    /// Called after every stored chunk; the returned closure removes it.
    func addStoredListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.lock()
        let id = nextListenerId
        nextListenerId += 1
        storedListeners[id] = listener
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.storedListeners[id] = nil
            self.lock.unlock()
        }
    }

    /// Deletes the other caches of the same video file (another model, window or size).
    func deleteOtherIdentities() {
        let fileManager = FileManager.default
        let root = directory.deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        let ownPath = videoKey.split(separator: "|").first
        for name in names {
            let other = root.appendingPathComponent(name, isDirectory: true)
            guard other.standardizedFileURL != directory.standardizedFileURL,
                  let data = try? Data(contentsOf: other.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            if manifest.videoKey.split(separator: "|").first == ownPath {
                try? fileManager.removeItem(at: other)
            }
        }
    }
}
