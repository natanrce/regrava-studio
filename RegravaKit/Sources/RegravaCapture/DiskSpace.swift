import Darwin
import Foundation

/// Free space of the volumes a recording writes to, checked while it records.
public enum DiskSpace {
    /// Below 1 GB (1024³ bytes) free, a recording is stopped.
    public static let minimumFreeBytes: Int64 = 1024 * 1024 * 1024

    /// How often the free space is checked while recording, in seconds.
    public static let checkInterval: TimeInterval = 2.5

    /// Bytes available to the user on the volume of `url` (`statfs`), nil when unknown.
    public static func freeBytes(at url: URL) -> Int64? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    /// Whether any of the volumes is too full to keep recording. Volumes whose free space is
    /// unknown are skipped; when none is known the recording goes on.
    public static func shouldStopRecording(freeBytes: [Int64?]) -> Bool {
        freeBytes.contains { free in free.map { $0 < minimumFreeBytes } ?? false }
    }
}
