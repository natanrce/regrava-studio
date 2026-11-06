import Foundation
import RegravaCore

/// How much a demand for a moment of the recording matters: an export's over the editor's.
public enum AnalysisDemandPriority: Int, Sendable, Comparable {
    case preview
    case export

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One sensitive data scan of a project's recording, shared by everyone asking for it with the
/// same inputs (the editor's preview, an export): its latest partial result, then its result.
public final class SharedSensitiveDataScan: @unchecked Sendable {
    /// A partial result with the order it was delivered in (1, 2, …).
    public struct Partial: Sendable {
        public let sequence: Int
        public let result: SensitiveDataScanner.PartialResult
    }

    let key: SensitiveDataScans.Key
    private let condition = NSCondition()
    private var _latest: Partial?
    private var _result: [SensitiveDataDetection]?
    private var _failure: Error?
    private var _isSettled = false
    private var observers: [Int: @Sendable (SensitiveDataScanner.PartialResult) -> Void] = [:]
    private var waiters: [Int: CheckedContinuation<[SensitiveDataDetection], Error>] = [:]
    private var released: Set<Int> = []
    private var nextToken = 0
    private var holders = 0
    private var task: Task<Void, Never>?

    init(key: SensitiveDataScans.Key) {
        self.key = key
    }

    /// The latest partial result (nil before the first).
    public var latest: Partial? { condition.withLock { _latest } }
    /// The complete result, once the scan finished.
    public var result: [SensitiveDataDetection]? { condition.withLock { _result } }
    /// Finished or failed.
    public var isSettled: Bool { condition.withLock { _isSettled } }

    func start(_ body: @escaping @Sendable (SharedSensitiveDataScan) async throws -> [SensitiveDataDetection]) {
        task = Task.detached(priority: .utility) { [self] in
            do {
                settle(.success(try await body(self)))
            } catch {
                settle(.failure(error))
            }
        }
    }

    func deliver(_ partial: SensitiveDataScanner.PartialResult) {
        condition.lock()
        guard !_isSettled else { condition.unlock(); return }
        let sequence = (_latest?.sequence ?? 0) + 1
        _latest = Partial(sequence: sequence, result: partial)
        let current = Array(observers.values)
        condition.broadcast()
        condition.unlock()
        for observer in current { observer(partial) }
    }

    func settle(_ outcome: Result<[SensitiveDataDetection], Error>) {
        condition.lock()
        _isSettled = true
        switch outcome {
        case .success(let detections): _result = detections
        case .failure(let error): _failure = error
        }
        let pending = waiters
        waiters = [:]
        observers = [:]
        condition.broadcast()
        condition.unlock()
        SensitiveDataScans.forget(self)
        for (_, waiter) in pending { waiter.resume(with: outcome) }
    }

    /// Holds the scan running; `observer` gets the latest partial result now and every later one.
    /// Returns the hold's token.
    func hold(observer: (@Sendable (SensitiveDataScanner.PartialResult) -> Void)?) -> Int {
        condition.lock()
        nextToken += 1
        let token = nextToken
        holders += 1
        if let observer, !_isSettled { observers[token] = observer }
        let latest = _latest
        condition.unlock()
        if let observer, let latest { observer(latest.result) }
        return token
    }

    /// Lets go of a hold: the scan stops when nobody holds it.
    func release(_ token: Int) {
        condition.lock()
        guard !released.contains(token) else { condition.unlock(); return }
        released.insert(token)
        holders -= 1
        observers[token] = nil
        let waiter = waiters.removeValue(forKey: token)
        let stops = holders == 0 && !_isSettled
        condition.unlock()
        waiter?.resume(throwing: CancellationError())
        if stops {
            SensitiveDataScans.forget(self)
            task?.cancel()
        }
    }

    /// The complete result for the hold `token` (throws the scan's failure; a released hold
    /// throws a cancellation).
    func value(token: Int) async throws -> [SensitiveDataDetection] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SensitiveDataDetection], Error>) in
            condition.lock()
            if let result = _result {
                condition.unlock()
                continuation.resume(returning: result)
            } else if let failure = _failure {
                condition.unlock()
                continuation.resume(throwing: failure)
            } else if released.contains(token) {
                condition.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[token] = continuation
                condition.unlock()
            }
        }
    }

    /// Blocks until `isDone` holds for the latest partial result, the scan settles or `shouldStop`
    /// returns true (checked every 100 ms).
    func wait(until isDone: (Partial?) -> Bool, shouldStop: () -> Bool) {
        condition.lock()
        defer { condition.unlock() }
        while !_isSettled, !isDone(_latest), !shouldStop() {
            condition.wait(until: Date().addingTimeInterval(0.1))
        }
    }
}

/// The sensitive data scans running in the app, one per recording and inputs, and what each
/// project's viewers ask to be scanned first.
public enum SensitiveDataScans {
    struct Key: Hashable, Sendable {
        let video: String
        let phrases: [String]
        let detectFaces: Bool
    }

    private struct Demand {
        let recordingTimeMs: Double
        let priority: AnalysisDemandPriority
        let order: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [Key: SharedSensitiveDataScan] = [:]
    nonisolated(unsafe) private static var demands: [String: [String: Demand]] = [:]
    nonisolated(unsafe) private static var demandCount = 0

    private static func projectKey(_ bundle: URL) -> String { bundle.standardizedFileURL.path }

    /// What `requesterId` looks at in the project at `bundle` (recording ms), nil when nothing.
    public static func setDemand(bundle: URL, requesterId: String, recordingTimeMs: Double?, priority: AnalysisDemandPriority) {
        lock.lock()
        defer { lock.unlock() }
        let project = projectKey(bundle)
        if let recordingTimeMs {
            demandCount += 1
            demands[project, default: [:]][requesterId] = Demand(recordingTimeMs: recordingTimeMs, priority: priority, order: demandCount)
        } else {
            demands[project]?[requesterId] = nil
            if demands[project]?.isEmpty == true { demands[project] = nil }
        }
    }

    /// The moment a scan of the project starts from: the latest demand of the highest priority.
    public static func nextDemandMs(bundle: URL) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return demands[projectKey(bundle)]?.values.max { ($0.priority, $0.order) < ($1.priority, $1.order) }?.recordingTimeMs
    }

    /// The scan of `video` with these inputs: the running one, or a new one starting from the
    /// project's demand. Its partial results are also kept in the project.
    static func shared(video: URL, phrases: [String], detectFaces: Bool, bundle: URL, options: SensitiveDataScanner.Options) -> SharedSensitiveDataScan {
        let key = Key(video: video.standardizedFileURL.path, phrases: phrases, detectFaces: detectFaces)
        lock.lock()
        if let scan = running[key] {
            lock.unlock()
            return scan
        }
        let scan = SharedSensitiveDataScan(key: key)
        running[key] = scan
        lock.unlock()
        scan.start { scan in
            try await SensitiveDataScanner.scan(video: video, phrases: phrases, detectFaces: detectFaces, options: options, bundle: bundle,
                                                demandMs: nextDemandMs(bundle: bundle), onPartialResult: { scan.deliver($0) })
        }
        return scan
    }

    static func forget(_ scan: SharedSensitiveDataScan) {
        lock.lock()
        if running[scan.key] === scan { running[scan.key] = nil }
        lock.unlock()
    }

    /// Scans the recording, sharing a scan already running with the same inputs:
    /// `onPartialResult` gets its latest partial result first. Cancelling stops the scan unless
    /// someone else still holds it.
    public static func scan(video: URL, phrases: [String], detectFaces: Bool, bundle: URL, options: SensitiveDataScanner.Options = .init(),
                            onPartialResult: @escaping @Sendable (SensitiveDataScanner.PartialResult) -> Void) async throws -> [SensitiveDataDetection] {
        let scan = shared(video: video, phrases: phrases, detectFaces: detectFaces, bundle: bundle, options: options)
        let token = scan.hold(observer: onPartialResult)
        return try await withTaskCancellationHandler {
            defer { scan.release(token) }
            return try await scan.value(token: token)
        } onCancel: {
            scan.release(token)
        }
    }
}
