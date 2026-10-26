import CoreGraphics
import Darwin
import Foundation

// `SensitiveDataCache`, the on-disk evidence cache, and `ChunkGrid` helpers.
// Layout on disk (all binary files are `EvidenceFile`s):
//   <root>/evidence-<shortHash(identity)>/manifest.json
//                                         chunk-%06d.evidence     (version 2, ChunkEvidence)
//                                         <layer>/chunk-%06d.layer (faces version 2, phrase version 1)
//                                         <layer>/piece-%06d.tracks (version 1, [FaceFollower.Track])
//                                         edges.memo              (version 1, [UInt64: Double])
//                                         claims/chunk-%06d.claim (the claiming process's pid)

extension SD.ChunkGrid: CustomStringConvertible {
    /// description: the chunk ends joined by ",".
    var description: String {
        endsMs.map { $0.description }.joined(separator: ",")
    }

    /// forVideo(durationMs:lanes:): chunks of duration / lanes rounded down to 2 s, at least 4 s; from 24 s on,
    /// 24 s chunks after a 4, 4, 8, 8 s ramp; the last chunk ends at the duration (at least 1).
    static func forVideo(durationMs: Int, lanes: Int) -> SD.ChunkGrid {
        var chunkMs = durationMs / max(lanes, 1) / 2000 * 2000
        var ramp: [Int] = []
        if chunkMs < 4000 {
            chunkMs = 4000
        } else if chunkMs >= 24000 {
            // Long chunks start with a ramp of short ones so the first results arrive early.
            ramp = [4000, 4000, 8000, 8000]
            chunkMs = 24000
        }
        var ends: [Int] = []
        var endMs = 0
        for stepMs in ramp {
            endMs += stepMs
            if endMs >= durationMs { break }
            ends.append(endMs)
        }
        var nextMs = endMs + chunkMs
        while nextMs < durationMs {
            ends.append(nextMs)
            nextMs += chunkMs
        }
        ends.append(max(durationMs, 1))
        return SD.ChunkGrid(endsMs: ends)
    }
}

extension SD {
    final class SensitiveDataCache {
        let directory: URL
        let grid: ChunkGrid
        let durationMs: Int
        let widthPx: Int
        let heightPx: Int
        private let root: URL
        private let videoKey: String
        private let claimsDirectory: URL
        private let fileManager: FileManager

        /// `Manifest`: written as manifest.json with the default JSONEncoder.
        struct Manifest: Codable, Equatable {
            let formatVersion: Int
            let videoKey: String
            let parameters: String
            let durationMs: Int
            let widthPx: Int
            let heightPx: Int
        }

        static let formatVersion = 2

        /// init(videoPath:root:durationMs:widthPx:heightPx:grid:parameters:)
        init(videoPath: String, root: URL?, durationMs: Int, widthPx: Int, heightPx: Int, grid: ChunkGrid, parameters: String) throws {
            fileManager = FileManager.default
            self.root = root ?? Self.root(forVideoAt: videoPath)
            self.grid = grid
            let parameters = parameters + "|" + grid.description
            self.durationMs = durationMs
            self.widthPx = widthPx
            self.heightPx = heightPx
            videoKey = Self.videoKey(forVideoAt: videoPath)
            let manifest = Manifest(formatVersion: Self.formatVersion, videoKey: videoKey, parameters: parameters,
                                    durationMs: durationMs, widthPx: widthPx, heightPx: heightPx)
            let identity = "\(Self.formatVersion)|\(videoKey)|\(parameters)|\(durationMs)|\(widthPx)x\(heightPx)"
            directory = self.root.appendingPathComponent("evidence-" + SD.shortHash(identity), isDirectory: true)
            claimsDirectory = directory.appendingPathComponent("claims", isDirectory: true)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL) {
                let existing = try? JSONDecoder().decode(Manifest.self, from: data)
                if existing != manifest {
                    try? fileManager.removeItem(at: directory)
                }
            }
            try fileManager.createDirectory(at: claimsDirectory, withIntermediateDirectories: true, attributes: nil)
            if !fileManager.fileExists(atPath: manifestURL.path) {
                let data = try JSONEncoder().encode(manifest)
                try data.write(to: manifestURL, options: .atomic)
            }
        }

        /// root(forVideoAt:): `<bundle>.screenstudio/cache/sensitive-data/` for a video inside a
        /// `.screenstudio` project bundle, else `<NSTemporaryDirectory>/sensitive-data/`.
        static func root(forVideoAt videoPath: String) -> URL {
            let components = URL(fileURLWithPath: videoPath).standardizedFileURL.pathComponents
            for (index, component) in components.enumerated() where component.hasSuffix(".screenstudio") {
                let bundle = NSString.path(withComponents: Array(components[...index]))
                return URL(fileURLWithPath: bundle, isDirectory: true)
                    .appendingPathComponent("cache", isDirectory: true)
                    .appendingPathComponent("sensitive-data", isDirectory: true)
            }
            return FileManager.default.temporaryDirectory.appendingPathComponent("sensitive-data", isDirectory: true)
        }

        /// videoKey(forVideoAt:): "<path>|<size or -1>|<Int(mtime) or 0>", where <path> is the path inside the
        /// `.screenstudio` bundle for a video in a project (so the key survives moving the project), else the
        /// standardized path.
        static func videoKey(forVideoAt videoPath: String) -> String {
            let url = URL(fileURLWithPath: videoPath).standardizedFileURL
            var bundleRelativePath: String?
            let components = url.pathComponents
            if let index = components.firstIndex(where: { $0.hasSuffix(".screenstudio") }) {
                bundleRelativePath = NSString.path(withComponents: Array(components[(index + 1)...]))
            }
            let attributes = (try? FileManager.default.attributesOfItem(atPath: videoPath)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (bundleRelativePath ?? url.path) + "|" + size.description + "|" + Int(modified).description
        }

        private func chunkName(_ index: Int, _ suffix: String) -> String {
            "chunk-" + String(format: "%06d", index) + "." + suffix
        }

        /// The common read path: a missing/unreadable file is nil; a file that fails to
        /// decode is removed (errors ignored) and nil.
        private func read<T>(_ url: URL, version: Int, _ decode: (Data) throws -> T) -> T? {
            guard let file = try? Data(contentsOf: url) else { return nil }
            do {
                return try decode(try EvidenceFile.decode(file, version: version))
            } catch {
                try? fileManager.removeItem(at: url)
                return nil
            }
        }

        /// readEvidence(_:): nil unless the stored chunk index matches.
        func readEvidence(_ index: Int) -> ChunkEvidence? {
            let url = directory.appendingPathComponent(chunkName(index, "evidence"))
            guard let evidence = read(url, version: 2, { try ChunkEvidence(decoding: $0) }) else { return nil }
            return evidence.chunkIndex == index ? evidence : nil
        }

        /// write(_:version:to:): creates the parent directory, writes atomically.
        func write(_ payload: Data, version: Int, to url: URL) throws {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let file = try EvidenceFile.encode(payload, version: version)
            try file.write(to: url, options: .atomic)
        }

        /// The evidence file of a chunk (as written by ChunkSweep.complete, version 2).
        func evidenceURL(_ index: Int) -> URL {
            directory.appendingPathComponent(chunkName(index, "evidence"))
        }

        /// The layer file of a chunk: `<layer>/chunk-%06d.layer`.
        func layerURL(_ layer: String, _ index: Int) -> URL {
            directory.appendingPathComponent(layer, isDirectory: true).appendingPathComponent(chunkName(index, "layer"))
        }

        /// readFaces(_:_:)
        func readFaces(_ layer: String, _ index: Int) -> ChunkFaces? {
            read(layerURL(layer, index), version: 2, { try ChunkFaces(decoding: $0) })
        }

        /// A phrase layer of a chunk (version 1).
        func readPhrase(_ layer: String, _ index: Int) -> ChunkPhrase? {
            read(layerURL(layer, index), version: 1, { try ChunkPhrase(decoding: $0) })
        }

        /// faceTracksURL(_:piece:)
        private func faceTracksURL(_ layer: String, piece: Int) -> URL {
            directory.appendingPathComponent(layer, isDirectory: true)
                .appendingPathComponent("piece-" + String(format: "%06d", piece) + ".tracks")
        }

        /// A face-tracks payload: count, tracks, no trailing bytes.
        static func decodeFaceTracks(_ payload: Data) throws -> [FaceTrack] {
            var reader = BinaryReader(payload)
            let count = Int(try reader.littleEndian(Int64.self))
            var tracks: [FaceTrack] = []
            if count != 0 { tracks.reserveCapacity(count) }
            for _ in 0..<count { tracks.append(try FaceTrack(reading: &reader)) }
            guard reader.offset == reader.bytes.count else { throw EvidenceDecodingError(reason: "trailing bytes") }
            return tracks
        }

        /// The face-tracks payload.
        static func encodeFaceTracks(_ tracks: [FaceTrack]) -> Data {
            var writer = BinaryWriter()
            writer.write(Int64(tracks.count))
            for track in tracks { track.write(into: &writer) }
            return writer.data
        }

        /// readFaceTracks(_:piece:) (version 1).
        func readFaceTracks(_ layer: String, piece: Int) -> [FaceTrack]? {
            read(faceTracksURL(layer, piece: piece), version: 1, Self.decodeFaceTracks)
        }

        /// writeFaceTracks(_:layer:piece:)
        func writeFaceTracks(_ tracks: [FaceTrack], layer: String, piece: Int) throws {
            try write(Self.encodeFaceTracks(tracks), version: 1, to: faceTracksURL(layer, piece: piece))
        }

        /// An edge-memo payload: count, then (key, value) pairs; later keys win;
        /// no trailing-bytes check.
        static func decodeEdges(_ payload: Data) throws -> [UInt64: Double] {
            var reader = BinaryReader(payload)
            var edges: [UInt64: Double] = [:]
            let count = Int(try reader.littleEndian(Int64.self))
            for _ in 0..<count {
                let key = UInt64(bitPattern: try reader.littleEndian(Int64.self))
                let value = Double(bitPattern: try reader.littleEndian(UInt64.self))
                edges[key] = value
            }
            return edges
        }

        /// The edge-memo payload: count, then the pairs sorted by key ascending.
        static func encodeEdges(_ edges: [UInt64: Double]) -> Data {
            var writer = BinaryWriter()
            writer.write(Int64(edges.count))
            for (key, value) in edges.sorted(by: { $0.key < $1.key }) {
                writer.write(key)
                writer.write(value)
            }
            return writer.data
        }

        /// readEdges(): [:] when missing or unreadable.
        func readEdges() -> [UInt64: Double] {
            read(directory.appendingPathComponent("edges.memo"), version: 1, Self.decodeEdges) ?? [:]
        }

        /// writeEdges(_:): merges into what is on disk (the new value wins), writes all.
        func writeEdges(_ edges: [UInt64: Double]) throws {
            let merged = readEdges().merging(edges) { _, new in new }
            try write(Self.encodeEdges(merged), version: 1, to: directory.appendingPathComponent("edges.memo"))
        }

        private func claimPath(_ index: Int) -> String {
            claimsDirectory.appendingPathComponent(chunkName(index, "claim")).path
        }

        /// claim(_:): O_CREAT|O_EXCL claim file holding our pid; a stale claim (dead pid) is
        /// removed and retried once.
        func claim(_ index: Int) -> Bool {
            let path = claimPath(index)
            var descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if descriptor < 0 {
                guard errno == EEXIST, Self.isStale(path) else { return false }
                try? fileManager.removeItem(atPath: path)
                descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if descriptor < 0 {
                    if errno == EEXIST, Self.isStale(path) {
                        try? fileManager.removeItem(atPath: path)
                    }
                    return false
                }
            }
            let pid = Data(getpid().description.utf8)
            pid.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
            return true
        }

        /// release(_:)
        func release(_ index: Int) {
            try? fileManager.removeItem(at: claimsDirectory.appendingPathComponent(chunkName(index, "claim")))
        }

        /// isStale(_:): the claim's pid (Int32, whitespace-trimmed) is not ours and no longer exists.
        private static func isStale(_ path: String) -> Bool {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespaces)) else { return false }
            if pid == getpid() { return false }
            if kill(pid, 0) != 0 { return errno == ESRCH }
            return false
        }

        /// deleteOtherIdentities(): removes the sibling evidence directories of the same video
        /// (same first `|` field of the manifest's videoKey).
        func deleteOtherIdentities() {
            let video = videoKey.split(separator: "|").first.map(String.init)
            let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names {
                let url = root.appendingPathComponent(name, isDirectory: true)
                if url.standardizedFileURL == directory.standardizedFileURL { continue }
                guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
                if manifest.videoKey.split(separator: "|").first.map(String.init) == video {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }
}

extension SD.Options {
    /// Options.init(): the defaults, with the environment overrides.
    init() {
        let environment = ProcessInfo.processInfo.environment
        videoPath = ""
        decodeThreads = 8
        ocrWorkers = 6
        sampleMs = 50
        settleMs = 120
        maxDirtyMs = 300
        minRereadMs = 400
        maxScrollingDirtyMs = environment["SENSITIVE_DATA_SCROLLING_DIRTY_MS"].flatMap { Int($0) } ?? 500
        changeThreshold = 20
        isTextRedacted = false
        customPhrases = []
        faceCascadePath = nil
        chunkMs = environment["SENSITIVE_DATA_CHUNK_MS"].flatMap { Int($0) }
        cacheRoot = environment["SENSITIVE_DATA_CACHE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        enlargesSmallText = environment["SENSITIVE_DATA_ENLARGE_SMALL_TEXT"] != "0"
        partialFinalLagMs = 60000
        demandMs = nil
        chunkOrder = nil
        stopAfterComputedChunks = nil
    }

    /// evidenceParameters
    var evidenceParameters: String {
        "\(sampleMs)|\(settleMs)|\(maxDirtyMs)|\(minRereadMs)|\(maxScrollingDirtyMs)|\(changeThreshold)|"
            + (enlargesSmallText ? "enlarged" : "as-is")
    }
}
