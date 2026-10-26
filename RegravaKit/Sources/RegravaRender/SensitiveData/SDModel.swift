@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

// The sensitive data scanner: finds sensitive text (emails, phone numbers, cards, keys, custom
// phrases) and faces across a recording and reports where and when each is visible.
// Everything lives in the namespace `SD` so its names (Scanner, Tracker, Options, GrayImage…) do
// not clash with the rest of RegravaRender. Times are whole milliseconds (`timeMs: Int`) almost
// everywhere; edges refined to a frame are fractional.

enum SD {}

extension SD {
    // MARK: Options

    /// `Options.init()` (the defaults with their environment overrides) is in Port/Cache/SensitiveDataCache.swift;
    /// the stored properties carry no default values so that init is the one `SD.Options()` calls.
    struct Options {
        var videoPath: String
        var decodeThreads: Int
        var ocrWorkers: Int
        var sampleMs: Int
        var settleMs: Int
        var maxDirtyMs: Int
        var minRereadMs: Int
        /// env SENSITIVE_DATA_SCROLLING_DIRTY_MS overrides.
        var maxScrollingDirtyMs: Int
        var changeThreshold: Int
        var isTextRedacted: Bool
        var customPhrases: [String]
        var faceCascadePath: String?
        /// env SENSITIVE_DATA_CHUNK_MS overrides.
        var chunkMs: Int?
        /// env SENSITIVE_DATA_CACHE_ROOT overrides.
        var cacheRoot: URL?
        /// env SENSITIVE_DATA_ENLARGE_SMALL_TEXT: only "0" turns it off.
        var enlargesSmallText: Bool
        var partialFinalLagMs: Int
        var demandMs: Int?
        var chunkOrder: [Int]?
        var stopAfterComputedChunks: Int?
    }

    // MARK: Tiles and change samples

    struct TileGrid {
        let widthPx: Int
        let heightPx: Int
        let tilesX: Int
        let tilesY: Int
    }

    struct ChangeSample {
        let timeMs: Int
        let isEverything: Bool
        /// Bitset of the tiles that changed since the previous sample.
        let changedTiles: [UInt64]
        let changedTileList: [Int]
        /// 16 block means per tile (`tile*16 + (by&3)*4 + bx`), when stored.
        let signatures: [UInt8]?
        let stripeShiftsPx: [Int16]
    }

    struct ChangeTimeline {
        let samples: [ChangeSample]
    }

    // MARK: Gray images and reads

    struct GrayImage {
        let bytes: Data
        let widthPx: Int
        let heightPx: Int
        /// Where the image's top-left sits in the video frame (video pixels, top-left origin).
        let originPx: CGPoint
        let cgImage: CGImage
    }

    struct RecognizedLine {
        let text: String
        let key: String
        let rect: CGRect
    }

    struct Finding {
        let kind: String
        let text: String
        let key: String
        let rect: CGRect
    }

    struct Observation {
        let timeMs: Int
        let region: CGRect
        let faceRegion: CGRect
        let lines: [RecognizedLine]
        let findings: [Finding]
        let firstTile: Int
        let tileSignatures: [UInt8]
    }

    struct PatternRule {
        let kind: String
        let priority: Int
        let regex: NSRegularExpression
    }

    struct PatternMatch {
        let kind: String
        let priority: Int
        let range: Range<String.Index>
    }

    struct PhraseLayer {
        let phrase: String
        let id: String
        let rule: PatternRule
        let candidateKeys: [String]
    }

    // MARK: Chunk evidence and layers (what the cache stores)

    struct ChunkGrid {
        let endsMs: [Int]
    }

    struct ChunkEvidence {
        let chunkIndex: Int
        let changeSamples: [ChangeSample]
        let sampledTimesMs: [Int]
        let reads: [Observation]
        let readHasPhotos: [Bool]
    }

    struct ChunkFaces {
        let facesByRead: [[Finding]]
    }

    struct ChunkPhrase {
        let findingsByRead: [Int: [Finding]]
    }

    struct ChunkLayers {
        var faceLayer: String?
        var phrases: [PhraseLayer]
    }

    struct ChunkScan {
        let evidence: ChunkEvidence
        let faces: ChunkFaces?
        let phrases: [String: ChunkPhrase]
    }

    struct StoredChunk {
        let evidence: ChunkEvidence
        let faces: ChunkFaces?
        let phrases: [String: ChunkPhrase]
    }

    struct EvidenceDecodingError: Error {
        let reason: String
    }

    struct SensitiveDataScanError: Error {
        let message: String
    }

    struct ScanStoppedError: Error {}

    // MARK: Tracking

    final class TrackedItem {
        let id: Int
        let kind: String
        var text: String
        let key: String
        var startMs: Int
        var endMs: Int
        var lastSeenMs: Int
        var lastSeenRect: CGRect
        var keyframes: [(timeMs: Int, rect: CGRect)]
        var missedAtMs: Int?
        var endIfGoneMs: Int
        var startEvidence: (absentMs: Int, presentMs: Int)?
        var endEvidence: (presentMs: Int, absentMs: Int)?
        var isTyped: Bool
        var exactStartMs: Double?
        var exactEndMs: Double?
        var heldKeyframes: [(timeMs: Double, rect: CGRect)]?

        init(id: Int, kind: String, text: String, key: String, startMs: Int, endMs: Int, lastSeenMs: Int, lastSeenRect: CGRect,
             keyframes: [(timeMs: Int, rect: CGRect)], missedAtMs: Int? = nil, endIfGoneMs: Int, startEvidence: (absentMs: Int, presentMs: Int)? = nil,
             endEvidence: (presentMs: Int, absentMs: Int)? = nil, isTyped: Bool = false, exactStartMs: Double? = nil, exactEndMs: Double? = nil,
             heldKeyframes: [(timeMs: Double, rect: CGRect)]? = nil) {
            self.id = id
            self.kind = kind
            self.text = text
            self.key = key
            self.startMs = startMs
            self.endMs = endMs
            self.lastSeenMs = lastSeenMs
            self.lastSeenRect = lastSeenRect
            self.keyframes = keyframes
            self.missedAtMs = missedAtMs
            self.endIfGoneMs = endIfGoneMs
            self.startEvidence = startEvidence
            self.endEvidence = endEvidence
            self.isTyped = isTyped
            self.exactStartMs = exactStartMs
            self.exactEndMs = exactEndMs
            self.heldKeyframes = heldKeyframes
        }
    }

    // MARK: Faces

    struct HalfFrame {
        let timeMs: Double
        let pixels: [UInt8]
    }

    /// `FaceFollower.Track` (the class `FaceFollower` declares `typealias Track = SD.FaceTrack`).
    struct FaceTrack {
        let startMs: Double
        let endMs: Double
        let path: [(timeMs: Double, point: CGPoint)]
        let boxes: [(timeMs: Double, rect: CGRect)]
        var isLostAtStart: Bool
        var isLostAtEnd: Bool
    }

    struct FaceSearchArea {
        let region: CGRect
        let original: GrayImage
        let crop: GrayImage
        let image: GrayImage
        let looks: [ArraySlice<UInt8>]?
        let lookKey: Int
    }

    // MARK: Results

    struct ProvisionalIsland {
        let detections: [[String: Any]]
        let fromMs: Double
        let toMs: Double
    }

    struct ScanOutput {
        let detections: [[String: Any]]
        let stats: [String: Any]
        let finalUpToMs: Double
        let analyzedUpToMs: Double
        var provisional: ProvisionalIsland?
    }
}
