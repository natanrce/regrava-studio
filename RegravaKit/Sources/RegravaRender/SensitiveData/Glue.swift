import Foundation

extension SD {
    /// Where scan progress (0…1) goes; set by `scan`.
    nonisolated(unsafe) static var reportProgress: (Double) -> Void = { _ in }

    /// One output line for the host. Only progress lines are delivered, through `reportProgress`.
    static let outputLock = NSLock()

    static func printJSON(_ object: [String: Any]) {
        guard (object["type"] as? String) == "progress", let progress = object["progress"] as? Double else { return }
        outputLock.lock()
        reportProgress(progress)
        outputLock.unlock()
    }
}
