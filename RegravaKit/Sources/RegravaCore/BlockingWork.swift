import Foundation

/// Set once when the task awaiting a `BlockingWork.run` body is cancelled; the body polls it.
public final class BlockingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Throws `CancellationError` once cancelled, as `Task.checkCancellation()` does.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Runs synchronous, blocking work (AVAssetReader / AVAssetWriter loops and the like) on a
/// thread of its own instead of a Swift concurrency thread. Those threads are few (one per
/// core); media reads blocked on all of them starve the framework work the reads wait for, and
/// nothing finishes. The awaiting task's cancellation sets the body's `BlockingCancellation`.
public enum BlockingWork {
    public static func run<T>(
        _ name: String,
        _ body: @escaping @Sendable (BlockingCancellation) throws -> T
    ) async throws -> T {
        let cancellation = BlockingCancellation()
        let qos = qualityOfService(Task.currentPriority)
        // The result crosses from the thread to the awaiting task exactly once.
        nonisolated(unsafe) var result: Result<T, Error>?
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let thread = Thread {
                    result = Result { try body(cancellation) }
                    continuation.resume()
                }
                thread.name = name
                thread.qualityOfService = qos
                thread.stackSize = 8 << 20
                thread.start()
            }
            return try result!.get()
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func qualityOfService(_ priority: TaskPriority) -> QualityOfService {
        let raw = priority.rawValue
        if raw >= TaskPriority.high.rawValue { return .userInitiated }
        if raw >= TaskPriority.medium.rawValue { return .default }
        if raw >= TaskPriority.utility.rawValue { return .utility }
        return .background
    }
}
