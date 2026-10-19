import Foundation

public enum ZoomMode: String, Codable, Sendable, CaseIterable {
    /// Camera follows groups of mouse activity.
    case auto
    /// Camera is fixed on `manualTarget`.
    case manual
}

/// "Zoom style": Classic (the screen zooms) or Glass Loupe.
public enum ZoomPresentation: String, Codable, Sendable, CaseIterable {
    case screen
    case loupe
}

public struct ZoomRange: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startMs: Double
    public var endMs: Double
    public var scale: Double
    public var mode: ZoomMode
    /// Normalized (0...1) point inside the recording used in manual mode.
    public var manualTarget: Vec2
    public var isDisabled: Bool
    /// Cut to the zoom instead of animating.
    public var isInstant: Bool
    /// Created by the auto-zoom generator (as opposed to by the user).
    public var isGenerated: Bool
    public var presentation: ZoomPresentation

    public init(
        id: UUID = UUID(),
        startMs: Double,
        endMs: Double,
        scale: Double = 2,
        mode: ZoomMode = .auto,
        manualTarget: Vec2 = .center01,
        isDisabled: Bool = false,
        isInstant: Bool = false,
        isGenerated: Bool = false,
        presentation: ZoomPresentation = .screen
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.scale = scale
        self.mode = mode
        self.manualTarget = manualTarget
        self.isDisabled = isDisabled
        self.isInstant = isInstant
        self.isGenerated = isGenerated
        self.presentation = presentation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startMs = try c.decode(Double.self, forKey: .startMs)
        endMs = try c.decode(Double.self, forKey: .endMs)
        scale = c.value(.scale, default: 2)
        mode = c.value(.mode, default: .auto)
        manualTarget = c.value(.manualTarget, default: .center01)
        isDisabled = c.value(.isDisabled, default: false)
        isInstant = c.value(.isInstant, default: false)
        isGenerated = c.value(.isGenerated, default: false)
        presentation = c.value(.presentation, default: .screen)
    }

    /// Zoom level 1 with the classic style changes nothing on screen.
    public var hasNoVisualEffect: Bool { isDisabled || (scale <= 1 && presentation == .screen) }

    public var durationMs: Double { endMs - startMs }

    public func contains(_ timeMs: Double) -> Bool { timeMs >= startMs && timeMs <= endMs }

    public static let minimumDurationMs: Double = 100
    /// Duration of a zoom added on the timeline.
    public static let initialDurationMs: Double = 3000
}

/// A non-standard cursor image saved with the recording, stored as `cursors/<id>.png` in the
/// project bundle.
public struct RecordedCursor: Codable, Hashable, Sendable {
    public var id: String
    /// Hotspot and size in points (top-left origin).
    public var hotSpot: Vec2
    public var standardSize: Size2

    public init(id: String, hotSpot: Vec2, standardSize: Size2) {
        self.id = id
        self.hotSpot = hotSpot
        self.standardSize = standardSize
    }
}

public struct RecordingInfo: Codable, Hashable, Sendable {
    public var videoFileName: String
    /// Size of the recorded video in pixels.
    public var videoSize: Size2
    /// Pixels per point of the captured display (2 on Retina).
    public var pointPixelScale: Double
    public var durationMs: Double
    public var fps: Int
    public var createdAt: Date
    public var cursors: [RecordedCursor]
    /// Source of each audio track of the recording, in track order.
    public var audioSources: [AudioSource]
    /// Webcam movie in the project folder, on the same timeline as the screen.
    public var cameraFileName: String?
    public var cameraSize: Size2?

    public init(
        videoFileName: String = "recording.mov",
        videoSize: Size2,
        pointPixelScale: Double,
        durationMs: Double,
        fps: Int,
        createdAt: Date = Date(),
        cursors: [RecordedCursor] = [],
        audioSources: [AudioSource] = [],
        cameraFileName: String? = nil,
        cameraSize: Size2? = nil
    ) {
        self.videoFileName = videoFileName
        self.videoSize = videoSize
        self.pointPixelScale = pointPixelScale
        self.durationMs = durationMs
        self.fps = fps
        self.createdAt = createdAt
        self.cursors = cursors
        self.audioSources = audioSources
        self.cameraFileName = cameraFileName
        self.cameraSize = cameraSize
    }

    public var hasCamera: Bool { cameraFileName != nil }

    public var hasMicrophone: Bool { audioSources.contains(.microphone) }
    public var hasSystemAudio: Bool { audioSources.contains(.systemAudio) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoFileName = c.value(.videoFileName, default: "recording.mov")
        videoSize = try c.decode(Size2.self, forKey: .videoSize)
        pointPixelScale = c.value(.pointPixelScale, default: 1)
        durationMs = try c.decode(Double.self, forKey: .durationMs)
        fps = c.value(.fps, default: 60)
        createdAt = c.value(.createdAt, default: Date())
        cursors = c.value(.cursors, default: [])
        audioSources = c.value(.audioSources, default: [])
        cameraFileName = c.value(.cameraFileName, default: nil)
        cameraSize = c.value(.cameraSize, default: nil)
    }
}

public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int
    public var recording: RecordingInfo
    public var mouseEvents: [MouseEvent]
    public var zooms: [ZoomRange]
    public var style: StyleConfig
    public var cursor: CursorConfig
    public var animation: AnimationConfig
    public var autoZoom: AutoZoomConfig
    /// Recording flags ("Add recording marker"), in milliseconds.
    public var markersMs: [Double]
    /// Key presses and releases (`recording.keystrokes`); only their timing is kept.
    public var keystrokes: [Keystroke]
    /// Clips in source order (`scene.slices`).
    public var slices: [Slice]
    /// Sensitive data and highlight masks (`scene.masks`).
    public var masks: [MaskRange] = []
    public var audio = AudioConfig()
    /// Camera image settings (`cameraConfig`).
    public var camera = CameraConfig()
    /// Layout used where no layout range applies (`defaultLayout`).
    public var defaultLayout = DefaultCameraLayout()
    /// Camera layout ranges in source time (`scene.layouts`).
    public var cameraLayouts: [CameraLayoutRange] = []
    /// Start times of "Speed up typing" suggestions that were applied or removed
    /// (`resolved-typing-speed-increase-suggestions-v2`).
    public var resolvedTypingSuggestionsMs: [Double] = []

    public init(
        recording: RecordingInfo,
        mouseEvents: [MouseEvent],
        zooms: [ZoomRange] = [],
        style: StyleConfig = StyleConfig(),
        cursor: CursorConfig = CursorConfig(),
        animation: AnimationConfig = AnimationConfig(),
        autoZoom: AutoZoomConfig = AutoZoomConfig(),
        markersMs: [Double] = [],
        keystrokes: [Keystroke] = [],
        slices: [Slice]? = nil
    ) {
        self.formatVersion = 1
        self.recording = recording
        self.mouseEvents = mouseEvents.sorted { $0.timeMs < $1.timeMs }
        self.zooms = zooms
        self.style = style
        self.cursor = cursor
        self.animation = animation
        self.autoZoom = autoZoom
        self.markersMs = markersMs
        self.keystrokes = keystrokes.sorted { $0.timeMs < $1.timeMs }
        self.slices = (slices ?? Self.defaultSlices(durationMs: recording.durationMs)).sorted { $0.sourceStartMs < $1.sourceStartMs }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = c.value(.formatVersion, default: 1)
        recording = try c.decode(RecordingInfo.self, forKey: .recording)
        mouseEvents = c.value(.mouseEvents, default: [])
        zooms = c.value(.zooms, default: [])
        style = c.value(.style, default: StyleConfig())
        cursor = c.value(.cursor, default: CursorConfig())
        animation = c.value(.animation, default: AnimationConfig())
        autoZoom = c.value(.autoZoom, default: AutoZoomConfig())
        markersMs = c.value(.markersMs, default: [])
        keystrokes = c.value(.keystrokes, default: [])
        let stored: [Slice] = c.value(.slices, default: [])
        slices = stored.isEmpty ? Self.defaultSlices(durationMs: recording.durationMs) : stored.sorted { $0.sourceStartMs < $1.sourceStartMs }
        resolvedTypingSuggestionsMs = c.value(.resolvedTypingSuggestionsMs, default: [])
        masks = c.value(.masks, default: [])
        audio = c.value(.audio, default: AudioConfig())
        camera = c.value(.camera, default: CameraConfig())
        defaultLayout = c.value(.defaultLayout, default: DefaultCameraLayout())
        cameraLayouts = c.value(.cameraLayouts, default: [])
    }

    /// Output canvas size in pixels (aspect ratio from `style`).
    public var canvasSize: Size2 { style.canvasSize(videoSize: recording.videoSize) }

    /// Replaces generated zooms with a fresh set derived from the clicks, keeping user-made ones.
    public mutating func regenerateAutomaticZooms() {
        let generated = AutoZoomGenerator.generate(
            events: mouseEvents,
            durationMs: recording.durationMs,
            config: autoZoom
        )
        zooms = (zooms.filter { !$0.isGenerated } + generated).sorted { $0.startMs < $1.startMs }
    }
}

/// A project is stored as a folder (`*.regrava`) holding `project.json` and the video.
public enum ProjectStore {
    public static let fileExtension = "regrava"
    public static let manifestName = "project.json"

    public static func videoURL(bundle: URL, project: Project) -> URL {
        bundle.appendingPathComponent(project.recording.videoFileName)
    }

    /// Image of a recorded custom cursor.
    public static func cursorImageURL(bundle: URL, id: String) -> URL {
        bundle.appendingPathComponent("cursors", isDirectory: true).appendingPathComponent("\(id).png")
    }

    public static func save(_ project: Project, to bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: bundle.appendingPathComponent(manifestName), options: .atomic)
    }

    public static func load(from bundle: URL) throws -> Project {
        let data = try Data(contentsOf: bundle.appendingPathComponent(manifestName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Project.self, from: data)
    }
}
