import Foundation

/// Reading a recording folder back, for finishing and for recovery.
public enum RecordingFolder {
    /// The files a playlist lists: its `#EXT-X-MAP` init segment and media segments, in order.
    static func playlistFiles(_ playlist: URL) -> (initSegment: String?, segments: [(file: String, seconds: Double)], ended: Bool)? {
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return nil }
        var initSegment: String?
        var segments: [(String, Double)] = []
        var pending: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:URI=\"") {
                initSegment = String(line.dropFirst("#EXT-X-MAP:URI=\"".count).prefix { $0 != "\"" })
            } else if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if !line.hasPrefix("#"), !line.isEmpty {
                segments.append((line, pending ?? 0))
                pending = nil
            }
        }
        return (initSegment, segments, text.contains("#EXT-X-ENDLIST"))
    }

    /// A playlist as one fragmented MP4: its init segment followed by every listed segment that
    /// is on disk ("every sample copied as it is"). Written beside and moved in when complete.
    public static func flatten(_ playlist: URL, to output: URL) throws {
        let directory = playlist.deletingLastPathComponent()
        guard let files = playlistFiles(playlist), let initSegment = files.initSegment else {
            throw CaptureError.failed("\(playlist.lastPathComponent) has no #EXT-X-MAP init segment")
        }
        guard !files.segments.isEmpty else { throw CaptureError.failed("\(playlist.lastPathComponent) lists no segments") }
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(contentsOf: directory.appendingPathComponent(initSegment)))
        for segment in files.segments {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(segment.file)) else { break }
            try handle.write(contentsOf: data)
        }
        try handle.close()
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }
}
