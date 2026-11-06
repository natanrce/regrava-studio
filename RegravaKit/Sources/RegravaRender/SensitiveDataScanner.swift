import Foundation
import RegravaCore

/// Finds sensitive text (emails, phone numbers, cards, keys, addresses, identifiers, custom
/// phrases) and faces across a recording, and reports where and when each is visible.
///
/// The video is scanned in chunks; what a chunk's scan saw is stored in the evidence cache
/// (`<bundle>/cache/sensitive-data/`), with the custom phrases and the face search as layers of
/// their own, so a scan with other phrases or with faces turned on only reads what it lacks.
/// Detections come from every chunk's evidence together.
public enum SensitiveDataScanner {
    /// Scan parameters. The defaults are the scanner's own (some can be overridden by environment
    /// variables: SENSITIVE_DATA_SCROLLING_DIRTY_MS, SENSITIVE_DATA_CHUNK_MS,
    /// SENSITIVE_DATA_CACHE_ROOT, SENSITIVE_DATA_ENLARGE_SMALL_TEXT).
    public struct Options: Sendable {
        /// Chunks scanned at once (decode lanes).
        public var decodeThreads: Int
        /// Text recognitions running at once.
        public var ocrWorkers: Int
        /// Change sampling interval.
        public var sampleMs: Int
        /// How long a row must be still before it is read.
        public var settleMs: Int
        /// A changed tile is read after this long even when it never settles.
        public var maxDirtyMs: Int
        /// Minimum gap between two reads of the same rows.
        public var minRereadMs: Int
        /// The dirty limit while the screen scrolls.
        public var maxScrollingDirtyMs: Int
        /// Block mean difference, in 8-bit luma levels, that counts as a change.
        public var changeThreshold: Int
        /// Small text is read again enlarged.
        public var enlargesSmallText: Bool
        /// How far behind the stored chunks a partial result's `finalUpToMs` stays.
        public var partialFinalLagMs: Int
        /// Fixed chunk length instead of the default grid.
        public var chunkMs: Int?
        /// The detections' text comes back starred.
        public var isTextRedacted: Bool

        public init() {
            let d = SD.Options()
            decodeThreads = d.decodeThreads
            ocrWorkers = d.ocrWorkers
            sampleMs = d.sampleMs
            settleMs = d.settleMs
            maxDirtyMs = d.maxDirtyMs
            minRereadMs = d.minRereadMs
            maxScrollingDirtyMs = d.maxScrollingDirtyMs
            changeThreshold = d.changeThreshold
            enlargesSmallText = d.enlargesSmallText
            partialFinalLagMs = d.partialFinalLagMs
            chunkMs = d.chunkMs
            isTextRedacted = d.isTextRedacted
        }
    }

    /// What a scan found so far: the chunks stored from the video's start on, up to `analyzedUpToMs`,
    /// resolved as the complete scan resolves them. Up to `finalUpToMs` the covers are the complete
    /// scan's; past it they may still change. `provisionalDetections` are those of the chunks stored
    /// around `demandMs` (apart from those from the start), resolved on their own over
    /// `provisionalFromMs`…`provisionalToMs` (both 0 when there are none): a preview there can cover
    /// them now; an export never draws them.
    public struct PartialResult: Sendable {
        public var detections: [SensitiveDataDetection]
        public var finalUpToMs: Double
        public var analyzedUpToMs: Double
        public var provisionalDetections: [SensitiveDataDetection]
        public var provisionalFromMs: Double
        public var provisionalToMs: Double
    }

    /// The default chunk grid of a video (chunk end times in ms).
    /// `lanes`: the decode lanes the grid is split for (the scan's `decodeThreads` when nil).
    public static func chunkBoundaries(durationMs: Double, lanes: Int? = nil) -> [Double] {
        [0] + SD.ChunkGrid.forVideo(durationMs: Int(durationMs), lanes: lanes ?? SD.Options().decodeThreads).endsMs.map(Double.init)
    }

    /// The evidence cache of a project bundle.
    public static func cacheRoot(bundle: URL) -> URL {
        bundle.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("sensitive-data", isDirectory: true)
    }

    /// Loads the text recognition models so the first scan does not wait for them.
    public static func prewarm() {
        SD.prewarm()
    }

    /// Scans the whole recording. `progress` gets the partial detections from the start and the
    /// time up to which they are final.
    public static func scan(video: URL, phrases: [String], detectFaces: Bool, options: Options = Options(), bundle: URL? = nil,
                            demandMs: Double? = nil,
                            progress: @escaping @Sendable ([SensitiveDataDetection], Double) -> Void) async throws -> [SensitiveDataDetection] {
        try await scan(video: video, phrases: phrases, detectFaces: detectFaces, options: options, bundle: bundle, demandMs: demandMs,
                       onPartialResult: { progress($0.detections, $0.finalUpToMs) })
    }

    /// Scans the whole recording, with the full partial results (`onPartialResult`) and the scanned
    /// fraction (`onProgress`, 0…1). The evidence cache is kept under `bundle` (or next to the video:
    /// in a `.regrava` project, else in the temporary directory). `demandMs`: the moment someone
    /// looks at; the chunks nearest it are scanned first.
    public static func scan(video: URL, phrases: [String], detectFaces: Bool, options: Options = Options(), bundle: URL? = nil,
                            demandMs: Double? = nil, onPartialResult: @escaping @Sendable (PartialResult) -> Void,
                            onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [SensitiveDataDetection] {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SensitiveDataDetection], Error>) in
                let thread = Thread {
                    do {
                        let output = try run(video: video, phrases: phrases, detectFaces: detectFaces, options: options, bundle: bundle,
                                             demandMs: demandMs, cancelled: cancelled, onPartialResult: onPartialResult, onProgress: onProgress)
                        continuation.resume(returning: detections(output.detections, stats: output.stats))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "sensitive data scan"
                thread.qualityOfService = .utility
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private static func run(video: URL, phrases: [String], detectFaces: Bool, options: Options, bundle: URL?, demandMs: Double?,
                            cancelled: CancelFlag, onPartialResult: @escaping @Sendable (PartialResult) -> Void,
                            onProgress: (@Sendable (Double) -> Void)?) throws -> SD.ScanOutput {
        // One scan at a time: its state is global. A newer scan waits for the one being cancelled.
        while !SD.scanLock.try() {
            if cancelled.isSet { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { SD.scanLock.unlock() }
        SD.reportProgress = { onProgress?($0) }
        defer { SD.reportProgress = { _ in } }
        var o = SD.Options()
        o.videoPath = video.path
        o.customPhrases = phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        o.faceCascadePath = detectFaces ? bundledCascadePath : nil
        o.demandMs = demandMs.map { Int(max($0, 0)) }
        o.decodeThreads = options.decodeThreads
        o.ocrWorkers = options.ocrWorkers
        o.sampleMs = options.sampleMs
        o.settleMs = options.settleMs
        o.maxDirtyMs = options.maxDirtyMs
        o.minRereadMs = options.minRereadMs
        o.maxScrollingDirtyMs = options.maxScrollingDirtyMs
        o.changeThreshold = options.changeThreshold
        o.enlargesSmallText = options.enlargesSmallText
        o.partialFinalLagMs = options.partialFinalLagMs
        o.chunkMs = options.chunkMs
        o.isTextRedacted = options.isTextRedacted
        if let bundle, ProcessInfo.processInfo.environment["SENSITIVE_DATA_CACHE_ROOT"] == nil {
            o.cacheRoot = cacheRoot(bundle: bundle)
        }
        if detectFaces, o.faceCascadePath == nil {
            throw SD.SensitiveDataScanError(message: "Cannot read the face cascade at facefinder.cascade")
        }
        return try SD.runSensitiveDataScan(o, isCancelled: { cancelled.isSet }, onPartialResult: { output in
            onPartialResult(PartialResult(detections: detections(output.detections, stats: output.stats), finalUpToMs: output.finalUpToMs,
                                          analyzedUpToMs: output.analyzedUpToMs,
                                          provisionalDetections: output.provisional.map { detections($0.detections, stats: output.stats) } ?? [],
                                          provisionalFromMs: output.provisional?.fromMs ?? 0, provisionalToMs: output.provisional?.toMs ?? 0))
        })
    }

    /// The pico face cascade shipped in the resources.
    static var bundledCascadePath: String? {
        Bundle.module.url(forResource: "facefinder", withExtension: "cascade", subdirectory: "SensitiveData")?.path
    }

    /// The scan's detection objects as the project model's detections, of the recording's one
    /// session, sized as the scanned video (`stats` widthPx/heightPx).
    static func detections(_ objects: [[String: Any]], stats: [String: Any] = [:]) -> [SensitiveDataDetection] {
        let widthPx = number(stats["widthPx"]), heightPx = number(stats["heightPx"])
        return objects.map { object in
            let kind = object["kind"] as? String ?? ""
            let keyframes = (object["keyframes"] as? [[String: Any]] ?? []).map { k in
                SensitiveDataKeyframe(timeMs: number(k["timeMs"]), x: number(k["x"]), y: number(k["y"]),
                                      width: number(k["width"]), height: number(k["height"]))
            }
            // A kind outside the project model's list; none is produced by the finders, kept as a secret.
            return SensitiveDataDetection(id: object["id"] as? Int ?? 0, kind: SensitiveDataKind(rawValue: kind) ?? .secret,
                                          text: object["text"] as? String ?? "", startMs: number(object["startMs"]),
                                          endMs: number(object["endMs"]), isTyped: object["isTyped"] as? Bool ?? false, keyframes: keyframes,
                                          sessionIndex: 0, videoWidthPx: widthPx, videoHeightPx: heightPx)
        }
    }

    private static func number(_ value: Any?) -> Double {
        switch value {
        case let v as Double: v
        case let v as Int: Double(v)
        case let v as NSNumber: v.doubleValue
        default: 0
        }
    }
}

private final class CancelFlag: @unchecked Sendable {
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
