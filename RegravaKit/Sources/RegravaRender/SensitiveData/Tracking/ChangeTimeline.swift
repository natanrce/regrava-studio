import CoreGraphics
import Foundation

// Queries over the change samples of a recording: which tiles changed when, and what a tile
// looked like (its 16 block means) at a given time.

extension SD.ChangeTimeline {
    /// Index of the first sample later than `timeMs` (samples are sorted by time).
    func firstIndex(after timeMs: Int) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if timeMs < samples[mid].timeMs { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// What `tile` looked like at `atMs`: the signature stored by the latest sample at or before
    /// `atMs` that marks the tile as changed (or changes everything). Nil when no such sample
    /// exists or it stores no signature for the tile.
    func signature(ofTile tile: Int, atMs: Int) -> ArraySlice<UInt8>? {
        var index = firstIndex(after: atMs)
        while index >= 1 {
            let sample = samples[index - 1]
            if sample.isEverything || sample.changedTiles[tile >> 6] & (1 << UInt64(tile & 63)) != 0 {
                return sample.signature(ofTile: tile)
            }
            index -= 1
        }
        return nil
    }

    /// Times of the first and last sample in (afterMs, upToMs] where any of `tiles` changed.
    func changes(inAnyOf tiles: [Int], afterMs: Int, upToMs: Int) -> (firstMs: Int, lastMs: Int)? {
        var firstMs: Int?
        var lastMs: Int?
        var index = firstIndex(after: afterMs)
        while index < samples.count {
            let sample = samples[index]
            if upToMs < sample.timeMs { break }
            if sample.hasChange(inAnyOf: tiles) {
                if firstMs == nil { firstMs = sample.timeMs }
                lastMs = sample.timeMs
            }
            index += 1
        }
        guard let firstMs, let lastMs else { return nil }
        return (firstMs: firstMs, lastMs: lastMs)
    }

    /// True when one sample in (afterMs, upToMs] changed many of `tiles` at once: at least half of
    /// them (rounded up) when there are more than 4 tiles, otherwise at least 3. Samples that change
    /// everything (cuts) do not count.
    func hasSuddenChange(in tiles: [Int], afterMs: Int, upToMs: Int) -> Bool {
        let needed = tiles.count > 4 ? (tiles.count + 1) >> 1 : 3
        var index = firstIndex(after: afterMs)
        while index < samples.count {
            let sample = samples[index]
            if upToMs < sample.timeMs { return false }
            if !sample.isEverything {
                var changed: [Int] = []
                for tile in tiles where sample.changedTiles[tile >> 6] & (1 << UInt64(tile & 63)) != 0 {
                    changed.append(tile)
                }
                if changed.count >= needed { return true }
            }
            index += 1
        }
        return false
    }
}

extension SD.ChangeSample {
    /// True when any of `tiles` changed in this sample (an empty list never changes).
    func hasChange(inAnyOf tiles: [Int]) -> Bool {
        for tile in tiles {
            if isEverything { return true }
            if changedTiles[tile >> 6] & (1 << UInt64(tile & 63)) != 0 { return true }
        }
        return false
    }

    /// The 16 block means of `tile` stored by this sample. A sample that changes everything stores
    /// every tile in tile order; otherwise it stores the tiles of `changedTileList`, in that order.
    func signature(ofTile tile: Int) -> ArraySlice<UInt8>? {
        guard let signatures else { return nil }
        if isEverything {
            return signatures[tile * 16 ..< (tile + 1) * 16]
        }
        var low = 0
        var high = changedTileList.count
        while low < high {
            let mid = (low + high) / 2
            if changedTileList[mid] < tile { low = mid + 1 } else { high = mid }
        }
        guard low < changedTileList.count, changedTileList[low] == tile else { return nil }
        return signatures[low * 16 ..< low * 16 + 16]
    }
}
