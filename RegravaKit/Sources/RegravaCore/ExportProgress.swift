import Foundation

/// Time left of a running export, from the pace measured since a starting sample. The
/// measurement starts over when the progress goes back, after a stall, or while paused (when
/// other project work slows the export down).
public struct ExportTimeEstimator: Sendable {
    public struct Sample: Equatable, Sendable {
        public var progress01: Double
        public var atMs: Double
    }

    /// Longer without progress than this is a stall.
    public static let stallTimeoutMs = 3000.0
    /// Shortest measurement an estimate is made from.
    public static let minMeasurementMs = 1000.0

    public let createdAtMs: Double
    public private(set) var measurementStart: Sample?
    public private(set) var latestSample: Sample?

    public init(createdAtMs: Double) {
        self.createdAtMs = createdAtMs
    }

    public mutating func reportProgress(_ progress01: Double, atMs: Double, isPaused: Bool) {
        let previous = latestSample
        if previous?.progress01 == progress01 { return }
        if progress01 <= 0 {
            measurementStart = nil
            latestSample = nil
            return
        }
        let sample = Sample(progress01: progress01, atMs: atMs)
        latestSample = sample
        if isPaused {
            measurementStart = nil
            return
        }
        if measurementStart == nil || previous == nil
            || progress01 < previous!.progress01
            || sample.atMs - previous!.atMs > Self.stallTimeoutMs {
            measurementStart = sample
        }
    }

    public func elapsedMs(nowMs: Double) -> Double { nowMs - createdAtMs }

    /// nil while there is no estimate yet ("Estimating time left...").
    public func timeLeftMs(nowMs: Double, isPaused: Bool) -> Double? {
        guard let start = measurementStart, let latest = latestSample, !isPaused else { return nil }
        if latest.progress01 >= 1 { return 0 }
        if nowMs - latest.atMs > Self.stallTimeoutMs { return nil }
        let measuredMs = latest.atMs - start.atMs
        if measuredMs < Self.minMeasurementMs { return nil }
        let msPerProgress = measuredMs / (latest.progress01 - start.progress01)
        let endMs = latest.atMs + (1 - latest.progress01) * msPerProgress
        return max(0, endMs - nowMs)
    }
}

/// Texts of the export progress screen.
public enum ExportProgressText {
    /// Percent decimals for an export expected to take `totalMs`: 1 over 5 minutes, 2 over 30.
    public static func percentDecimals(totalMs: Double) -> Int {
        totalMs > 30 * 60_000 ? 2 : totalMs > 5 * 60_000 ? 1 : 0
    }

    /// "42%" (floored), or with `decimals` digits.
    public static func percent(_ progress01: Double?, decimals: Int) -> String {
        guard let progress01 else { return "0%" }
        if decimals > 0 { return String(format: "%.\(decimals)f%%", progress01 * 100) }
        return "\(Int((progress01 * 100).rounded(.down)))%"
    }

    /// "05:07" under an hour, "1:02:07" from an hour; seconds rounded up.
    public static func duration(ms: Double) -> String {
        let seconds = Int((ms / 1000).rounded(.up))
        let secondsText = String(format: "%02d", seconds % 60)
        if seconds < 3600 { return String(format: "%02d", seconds / 60) + ":" + secondsText }
        return "\(seconds / 3600):" + String(format: "%02d", seconds % 3600 / 60) + ":" + secondsText
    }
}
