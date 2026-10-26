import CoreGraphics
import Dispatch
import Foundation

extension SD.SensitiveDataResolver {
    /// The face tracks of every chunk up to `endMs` that has a face sighting. Each chunk ("piece") is
    /// followed with the frames of the chunk before it and the two after it; pieces are reused from memory
    /// or the cache when known, otherwise followed on up to three threads (and remembered when final).
    func faceTracks(observations: [SD.Observation], samples: [SD.ChangeSample], sampledTimesMs: [Int], endMs: Int, isFinal: Bool,
                    resolved: inout Resolved) -> [SD.FaceFollower.Track] {
        guard let layer = layers.faceLayer else { return [] }
        let endsMs = cache.grid.endsMs
        var pieces: [Int] = []
        if !endsMs.isEmpty {
            let lastMs = max(endMs - 1, 0)
            let lastPiece = endsMs.firstIndex { lastMs < $0 } ?? endsMs.count - 1
            for piece in 0...lastPiece {
                let startMs = piece == 0 ? 0 : endsMs[piece - 1]
                let pieceEndMs = endsMs[piece]
                if observations.contains(where: { o in
                    startMs <= o.timeMs && o.timeMs < pieceEndMs && o.findings.contains { $0.kind == "face" }
                }) {
                    pieces.append(piece)
                }
            }
        }
        var known: [Int: [SD.FaceFollower.Track]] = [:]
        var missing: [Int] = []
        memoLock.lock()
        for piece in pieces {
            if faceTracks[piece] == nil, let stored = cache.readFaceTracks(layer, piece: piece) { faceTracks[piece] = stored }
            if let tracks = faceTracks[piece] { known[piece] = tracks } else { missing.append(piece) }
        }
        memoLock.unlock()

        let lock = NSLock()
        var decodedFrames = 0
        var followedFrames = 0
        let workers = min(missing.count, 3)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var w = worker
            while w < missing.count {
                let piece = missing[w]
                w += workers
                let windowStartMs = piece - 1 < 1 ? 0 : endsMs[piece - 2]
                let chunkEndMs = endsMs[min(piece + 2, endsMs.count - 1)]
                let windowEndMs = endMs <= chunkEndMs ? endMs : chunkEndMs
                let follower = SD.FaceFollower(
                    scanner: scanner,
                    observations: observations.filter { windowStartMs <= $0.timeMs && $0.timeMs < windowEndMs },
                    timeline: SD.ChangeTimeline(samples: samples.filter { windowStartMs <= $0.timeMs && $0.timeMs <= windowEndMs }),
                    sampledTimesMs: sampledTimesMs.filter { windowStartMs <= $0 && $0 <= windowEndMs },
                    endMs: windowEndMs)
                let pieceStartMs = piece == 0 ? 0 : endsMs[piece - 1]
                let pieceEndMs = windowEndMs <= endsMs[piece] ? windowEndMs : endsMs[piece]
                let tracks = follower.follow(pieceStartMs: pieceStartMs, pieceEndMs: pieceEndMs)
                lock.lock()
                known[piece] = tracks
                decodedFrames += follower.decodedFrames
                followedFrames += follower.followedFrames
                lock.unlock()
                // A piece whose window was cut short by a partial scan is not final yet.
                if !isFinal && endMs < chunkEndMs { continue }
                if remembersDecisions {
                    memoLock.lock()
                    faceTracks[piece] = tracks
                    memoLock.unlock()
                    try? cache.writeFaceTracks(tracks, layer: layer, piece: piece)
                }
            }
        }
        resolved.faceFollowDecodedFrames = decodedFrames
        resolved.faceFollowedFrames = followedFrames
        var all: [SD.FaceFollower.Track] = []
        for piece in pieces { all.append(contentsOf: known[piece] ?? []) }
        return all
    }
}
