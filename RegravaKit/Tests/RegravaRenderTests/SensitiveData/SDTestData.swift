import Foundation
@testable import RegravaRender

/// Reference data for the scanner tests: a 15 s screen recording and what a reference scan stored
/// and found for it. Tests that need it are skipped where it is absent.
enum SDTestData {
    /// Where the reference data lives. Its file paths are part of what was recorded (cache
    /// identities hash the video's path and modification date), so it is used from /tmp, restored
    /// there from a kept copy (SD_REFERENCE_BACKUP) when /tmp was cleared.
    static let root: String = {
        let root = ProcessInfo.processInfo.environment["SD_REFERENCE_DIR"] ?? "/tmp"
        let backup = ProcessInfo.processInfo.environment["SD_REFERENCE_BACKUP"]
            ?? NSHomeDirectory() + "/www/myself/research/screen-studio/sensitive-data-reference"
        let fm = FileManager.default
        for name in ["rgscan", "A-oracle", "B-oracle", "C-work"] {
            let target = root + "/" + name, source = backup + "/" + name
            guard !fm.fileExists(atPath: target), fm.fileExists(atPath: source) else { continue }
            try? fm.copyItem(atPath: source, toPath: target)
        }
        return root
    }()

    static func path(_ relative: String) -> String { root + "/" + relative }

    static let clip = ProcessInfo.processInfo.environment["SD_TEST_CLIP"] ?? SDTestData.path("rgscan/clip15.mov")
    static var hasClip: Bool { FileManager.default.fileExists(atPath: clip) }
    /// The reference scan's stored evidence (decoded) and outputs, next to the clip.
    static var hasReference: Bool {
        hasClip && FileManager.default.fileExists(atPath: SDTestData.path("rgscan/evidence-json")) && FileManager.default.fileExists(atPath: SDTestData.path("rgscan/orig_noface.json"))
    }
    /// Tests that read every frame of the clip with text recognition (minutes in debug builds): SD_LONG_TESTS=1.
    static var runsLongTests: Bool { ProcessInfo.processInfo.environment["SD_LONG_TESTS"] == "1" }

    static func scanner(_ options: SD.Options = SD.Options()) throws -> SD.Scanner {
        var options = options
        options.videoPath = clip
        return try SD.Scanner(options: options)
    }

    static func cache(for scanner: SD.Scanner) throws -> SD.SensitiveDataCache {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "sd-tests-\(UUID().uuidString)", isDirectory: true)
        return try SD.SensitiveDataCache(videoPath: clip, root: root, durationMs: scanner.durationMs, widthPx: scanner.grid.widthPx,
                                         heightPx: scanner.grid.heightPx, grid: SD.ChunkGrid(endsMs: [4000, 8000, 12000, 15116]),
                                         parameters: scanner.options.evidenceParameters)
    }
}
