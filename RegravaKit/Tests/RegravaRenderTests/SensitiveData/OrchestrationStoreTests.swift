import Foundation
import Testing
@testable import RegravaRender

struct ChunkStoreTests {
    static func chunk(_ index: Int) -> SD.StoredChunk {
        SD.StoredChunk(evidence: SD.ChunkEvidence(chunkIndex: index, changeSamples: [], sampledTimesMs: [], reads: [], readHasPhotos: []),
                       faces: nil, phrases: [:])
    }

    @Test func prefixAndIsland() {
        let store = SD.ChunkStore(chunkCount: 10)
        #expect(store.prefix().isEmpty)
        for index in [0, 1, 2, 5, 6, 7, 9] { store.chunks[index] = Self.chunk(index) }
        #expect(store.prefix().map(\.evidence.chunkIndex) == [0, 1, 2])
        #expect(store.island(around: 6).map(\.evidence.chunkIndex) == [5, 6, 7])
        #expect(store.island(around: 5).map(\.evidence.chunkIndex) == [5, 6, 7])
        #expect(store.island(around: 1).map(\.evidence.chunkIndex) == [0, 1, 2])
        #expect(store.island(around: 9).map(\.evidence.chunkIndex) == [9])
        #expect(store.island(around: 3).isEmpty)
        store.chunks[8] = Self.chunk(8)
        #expect(store.island(around: 9).map(\.evidence.chunkIndex) == [5, 6, 7, 8, 9])
    }
}
