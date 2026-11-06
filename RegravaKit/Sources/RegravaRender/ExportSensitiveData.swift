import Foundation
import RegravaCore

/// Hide sensitive data / Hide faces in an export that starts while the scan runs. A frame waits
/// until the latest partial result is final a second past it ("detecting sensitive data"), and
/// is drawn with that result's final detections only, never with those scanned ahead. Each
/// partial result drawn from is kept with the source times it covered, so the export can be
/// checked against the complete result at the end.
public final class ExportSensitiveData: @unchecked Sendable {
    private let scan: SharedSensitiveDataScan
    private let bundle: URL
    private let requesterId: String
    private let token: Int
    private let lock = NSLock()
    private var isStopped = false
    private var isDemanding = false
    private var used: [Int: (partial: SharedSensitiveDataScan.Partial, fromMs: Double, toMs: Double)] = [:]
    private var timelines: (sequence: Int, timeline: AutoMaskTimeline)?
    private var resultTimeline: AutoMaskTimeline?

    /// Joins (or starts) the scan of the project's recording with its inputs. The export's demand
    /// (`requesterId`, export priority) is the first frame's source time, so a scan it starts
    /// begins there.
    convenience init(project: Project, video: URL, bundle: URL, requesterId: String, firstSourceMs: Double, options: SensitiveDataScanner.Options = .init()) {
        let processing = project.processing
        SensitiveDataScans.setDemand(bundle: bundle, requesterId: requesterId, recordingTimeMs: firstSourceMs, priority: .export)
        let scan = SensitiveDataScans.shared(video: video, phrases: processing.sensitiveDataCustomPhrases, detectFaces: processing.autoMaskFaces,
                                             bundle: bundle, options: options)
        self.init(scan: scan, bundle: bundle, requesterId: requesterId, firstSourceMs: firstSourceMs)
    }

    /// Draws from `scan`, demanding `firstSourceMs` until a frame is drawn.
    init(scan: SharedSensitiveDataScan, bundle: URL, requesterId: String, firstSourceMs: Double) {
        self.scan = scan
        self.bundle = bundle
        self.requesterId = requesterId
        SensitiveDataScans.setDemand(bundle: bundle, requesterId: requesterId, recordingTimeMs: firstSourceMs, priority: .export)
        isDemanding = true
        token = scan.hold(observer: nil)
    }

    /// Partial results frames were drawn from so far.
    var usedPartialCount: Int { lock.withLock { used.count } }

    /// The detections a frame at `sourceMs` is drawn with, once it may be drawn: the complete
    /// result, else the final detections of the partial result final past it. Blocks until then
    /// (or until the export stops).
    func timeline(atSourceMs sourceMs: Double) -> AutoMaskTimeline {
        if !isReady(sourceMs) {
            setDemand(sourceMs)
            scan.wait(until: { partial in partial.map { SensitiveDataExportCheck.isReady(sourceMs: sourceMs, finalUpToMs: $0.result.finalUpToMs) } ?? false },
                      shouldStop: { lock.withLock { isStopped } })
        }
        setDemand(nil)
        if let result = scan.result {
            return lock.withLock {
                if let resultTimeline { return resultTimeline }
                let timeline = AutoMaskTimeline(detections: result.sorted { $0.startMs < $1.startMs })
                resultTimeline = timeline
                return timeline
            }
        }
        // A failed scan draws the last partial result's final detections.
        guard let partial = scan.latest else { return AutoMaskTimeline(detections: []) }
        return lock.withLock {
            let previous = used[partial.sequence]
            used[partial.sequence] = (partial, min(previous?.fromMs ?? sourceMs, sourceMs), max(previous?.toMs ?? sourceMs, sourceMs))
            if let timelines, timelines.sequence == partial.sequence { return timelines.timeline }
            let timeline = AutoMaskTimeline(detections: partial.result.detections.sorted { $0.startMs < $1.startMs })
            timelines = (partial.sequence, timeline)
            return timeline
        }
    }

    private func isReady(_ sourceMs: Double) -> Bool {
        if scan.isSettled { return true }
        guard let partial = scan.latest else { return false }
        return SensitiveDataExportCheck.isReady(sourceMs: sourceMs, finalUpToMs: partial.result.finalUpToMs)
    }

    /// While a frame waits the export demands its time; once it is drawn, nothing.
    private func setDemand(_ sourceMs: Double?) {
        lock.lock()
        let changes = sourceMs != nil || isDemanding
        isDemanding = sourceMs != nil
        lock.unlock()
        if changes {
            SensitiveDataScans.setDemand(bundle: bundle, requesterId: requesterId, recordingTimeMs: sourceMs, priority: .export)
        }
    }

    /// Whether frames were drawn from partial results the complete result does not match. Waits
    /// for the scan to finish; a failed scan is not stale.
    func isStale() async -> Bool {
        let uses = lock.withLock {
            used.values.map { SensitiveDataExportCheck.Use(detections: $0.partial.result.detections, finalUpToMs: $0.partial.result.finalUpToMs,
                                                           fromMs: $0.fromMs, toMs: $0.toMs) }
        }
        guard !uses.isEmpty, let result = try? await scan.value(token: token) else { return false }
        return !SensitiveDataExportCheck.isConsistent(uses, with: result)
    }

    /// The complete result, once the scan finished (nil when it failed).
    func completeResult() async -> [SensitiveDataDetection]? {
        try? await scan.value(token: token)
    }

    /// Stops waiting frames and lets go of the scan and the demand.
    func stop() {
        lock.withLock { isStopped = true }
        setDemand(nil)
        scan.release(token)
    }
}
