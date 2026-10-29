import Foundation
import RegravaCore

/// `metadata-raw.json`: what a recording folder holds, rewritten at the start and on every
/// change so a crash leaves enough to finish it from the folder alone. Times are host-clock
/// seconds (`ProcessInfo.systemUptime`).
public struct RecordingMetadata: Codable, Sendable {
    public struct Channel: Codable, Sendable {
        /// "display", "device", or an `AudioSource` raw value.
        public var source: String
        public var playlist: String
        /// Host time of the channel's first sample, once it arrived.
        public var startUptime: Double?
    }

    public struct Session: Codable, Sendable {
        public var index: Int
        /// The picture's first frame; nil until it arrived.
        public var startUptime: Double?
        /// Nil when a crash interrupted the session; the finalizer reads its playlist then.
        public var endUptime: Double?
        public var channels: [Channel]
    }

    /// A stream that runs through pauses and is cut to the sessions (webcam, apps' sound).
    public struct Continuous: Codable, Sendable {
        public var source: String
        public var playlist: String
        public var startUptime: Double?
        public var width: Double?
        public var height: Double?
    }

    public struct Orientation: Codable, Sendable {
        public var uptime: Double
        public var contentRect: Rect2
        public var angle: Double
        public var animation: DeviceOrientationChange.Animation
    }

    /// "recording" until finished, then "complete".
    public var state = "recording"
    public var videoSize = Size2(width: 0, height: 0)
    public var pointPixelScale = 1.0
    public var originX = 0.0
    public var originY = 0.0
    public var fps = 60
    public var flags: [String] = []
    public var sessions: [Session] = []
    public var continuous: [Continuous] = []
    public var markerUptimes: [Double] = []
    public var device: ExternalDeviceInfo?
    public var orientationChanges: [Orientation] = []

    public init() {}

    public static let fileName = "metadata-raw.json"
}

/// Writes a recording folder's metadata and event logs while it records.
@MainActor
final class RecordingJournal {
    let folder: URL
    private(set) var metadata = RecordingMetadata()
    private let mouse: StreamingJSONWriter
    private let keys: StreamingJSONWriter
    private var savedCursorIDs: Set<String> = []

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mouse = try StreamingJSONWriter(url: folder.appendingPathComponent(JournalFiles.mouse))
        keys = try StreamingJSONWriter(url: folder.appendingPathComponent(JournalFiles.keys))
        save()
    }

    func update(_ change: (inout RecordingMetadata) -> Void) {
        change(&metadata)
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: folder.appendingPathComponent(RecordingMetadata.fileName), options: .atomic)
    }

    func record(_ sample: MouseTracker.Sample) {
        mouse.append(JournalMouse(kind: sample.kind, uptime: sample.uptime, x: sample.location.x, y: sample.location.y, button: sample.button, cursorId: sample.cursorID, modifiers: sample.modifiers))
    }

    func record(_ sample: MouseTracker.KeySample) {
        keys.append(JournalKey(kind: sample.kind, uptime: sample.uptime, character: sample.character, modifiers: sample.modifiers, isARepeat: sample.isARepeat))
    }

    /// `cursors/<id>.png` and `cursors.json`, as soon as a custom cursor is first seen.
    func saveCursors(_ images: [CapturedCursorImage]) {
        let new = images.filter { !savedCursorIDs.contains($0.id) }
        guard !new.isEmpty else { return }
        let directory = folder.appendingPathComponent(JournalFiles.cursorsDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for image in new {
            try? image.pngData.write(to: directory.appendingPathComponent("\(image.id).png"))
            savedCursorIDs.insert(image.id)
        }
        let list = images.map { JournalCursor(id: $0.id, hotSpot: $0.hotSpot, size: $0.size) }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: folder.appendingPathComponent(JournalFiles.cursors), options: .atomic) }
    }

    func close() {
        mouse.close()
        keys.close()
    }
}

enum JournalFiles {
    static let mouse = "mousemoves-0.json"
    static let keys = "keystrokes-0.json"
    static let cursors = "cursors.json"
    static let cursorsDirectory = "cursors"
}

struct JournalMouse: Codable {
    var kind: MouseEventKind
    var uptime: Double
    var x: Double
    var y: Double
    var button: Int
    var cursorId: String?
    var modifiers: [KeyModifier]
}

struct JournalKey: Codable {
    var kind: Keystroke.Kind
    var uptime: Double
    var character: String
    var modifiers: [KeyModifier]
    var isARepeat: Bool
}

struct JournalCursor: Codable {
    var id: String
    var hotSpot: Vec2
    var size: Size2
}

/// A JSON array written as it grows (`StreamingJSONWriter`): `[`, one object per line ending in
/// `,`, committed on a timer, and `]` on close. A crash leaves it without its end, which `read`
/// accepts, as it skips a torn last line.
final class StreamingJSONWriter: @unchecked Sendable {
    static let commitInterval = 1.0
    private static let separator = Data(",\n".utf8)

    private let handle: FileHandle
    /// Disk writes, in order; `pending` is only swapped under `lock`, so appends never wait on them.
    private let queue = DispatchQueue(label: "regrava.capture.journal", qos: .utility)
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private var pending = Data()
    private var timer: DispatchSourceTimer?
    private var isClosed = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data("[\n".utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.commitInterval, repeating: Self.commitInterval)
        timer.setEventHandler { [weak self] in self?.write() }
        timer.resume()
        self.timer = timer
    }

    func append<T: Encodable>(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(value) else { return }
        pending.append(data)
        pending.append(Self.separator)
    }

    /// On `queue`.
    private func write() {
        guard !isClosed else { return }
        lock.lock()
        let data = pending
        pending = Data()
        lock.unlock()
        guard !data.isEmpty else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        timer?.cancel()
        timer = nil
        queue.sync {
            write()
            if !isClosed {
                try? handle.write(contentsOf: Data("]\n".utf8))
                try? handle.close()
                isClosed = true
            }
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        // Whole: the array closed after its last `,` (and `]` added when a crash left it open).
        var body = data[...]
        func trimEnd() { while let last = body.last, last == 0x20 || last == 0x0A || last == 0x0D || last == 0x09 { body.removeLast() } }
        trimEnd()
        if body.last == UInt8(ascii: "]") { body.removeLast(); trimEnd() }
        if body.last == UInt8(ascii: ",") { body.removeLast() }
        if let all = try? decoder.decode([T].self, from: body + Data("]".utf8)) { return all }
        // A torn line: one object per line, skipping what does not decode.
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line == "[" || line == "]" || line.isEmpty { return nil }
            if line.hasSuffix(",") { line.removeLast() }
            return try? decoder.decode(T.self, from: Data(line.utf8))
        }
    }
}
