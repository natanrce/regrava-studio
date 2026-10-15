import Foundation

public enum ZoomMode: String, Codable, Sendable, CaseIterable {
    /// Camera follows groups of mouse activity.
    case auto
    /// Camera is fixed on `manualTarget`.
    case manual
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

    public init(
        id: UUID = UUID(),
        startMs: Double,
        endMs: Double,
        scale: Double = 2,
        mode: ZoomMode = .auto,
        manualTarget: Vec2 = .center01,
        isDisabled: Bool = false,
        isInstant: Bool = false,
        isGenerated: Bool = false
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
    }

    public var durationMs: Double { endMs - startMs }

    public func contains(_ timeMs: Double) -> Bool { timeMs >= startMs && timeMs <= endMs }

    public static let minimumDurationMs: Double = 100
}

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255,
            alpha
        )
    }
}

public enum BackgroundStyle: Codable, Hashable, Sendable {
    case solid(RGBA)
    case linearGradient(from: RGBA, to: RGBA, angleDegrees: Double)

    public static let presets: [(name: String, style: BackgroundStyle)] = [
        ("Dusk", .linearGradient(from: RGBA(hex: 0x6A11CB), to: RGBA(hex: 0x2575FC), angleDegrees: 135)),
        ("Peach", .linearGradient(from: RGBA(hex: 0xFF9A8B), to: RGBA(hex: 0xFF6A88), angleDegrees: 135)),
        ("Mint", .linearGradient(from: RGBA(hex: 0x0BA360), to: RGBA(hex: 0x3CBA92), angleDegrees: 120)),
        ("Ocean", .linearGradient(from: RGBA(hex: 0x1E3C72), to: RGBA(hex: 0x2A5298), angleDegrees: 160)),
        ("Sunset", .linearGradient(from: RGBA(hex: 0xF7971E), to: RGBA(hex: 0xFFD200), angleDegrees: 135)),
        ("Graphite", .solid(RGBA(hex: 0x1C1C1E))),
        ("Paper", .solid(RGBA(hex: 0xF2F2F7))),
    ]
}

public struct StyleConfig: Codable, Hashable, Sendable {
    /// Output frame size in pixels.
    public var canvas: Size2
    /// Padding around the screen as a fraction of the canvas' shortest side.
    public var paddingRatio: Double
    /// Corner radius of the screen, in canvas pixels at rest.
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    public var background: BackgroundStyle
    /// When zoomed, the screen may grow over the padding until it fills the whole canvas.
    public var zoomFillsCanvas: Bool

    public init(
        canvas: Size2 = Size2(width: 1920, height: 1080),
        paddingRatio: Double = 0.08,
        cornerRadius: Double = 14,
        shadowRadius: Double = 36,
        shadowOpacity: Double = 0.45,
        background: BackgroundStyle = BackgroundStyle.presets[0].style,
        zoomFillsCanvas: Bool = true
    ) {
        self.canvas = canvas
        self.paddingRatio = paddingRatio
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
        self.zoomFillsCanvas = zoomFillsCanvas
    }
}

public struct CursorConfig: Codable, Hashable, Sendable {
    public var isVisible: Bool
    /// Multiplier over the system cursor size.
    public var sizeMultiplier: Double
    public var isSmoothingEnabled: Bool
    public var spring: SpringConfig
    public var showsClickRipple: Bool
    /// Distance in video pixels used to drop single-sample jumps (0 disables).
    public var spikeThreshold: Double

    public init(
        isVisible: Bool = true,
        sizeMultiplier: Double = 1.5,
        isSmoothingEnabled: Bool = true,
        spring: SpringConfig = .cursor,
        showsClickRipple: Bool = true,
        spikeThreshold: Double = 500
    ) {
        self.isVisible = isVisible
        self.sizeMultiplier = sizeMultiplier
        self.isSmoothingEnabled = isSmoothingEnabled
        self.spring = spring
        self.showsClickRipple = showsClickRipple
        self.spikeThreshold = spikeThreshold
    }
}

public struct AnimationConfig: Codable, Hashable, Sendable {
    public var screenSpring: SpringConfig
    /// Start moving the camera slightly before a zoom begins.
    public var startsZoomEarly: Bool

    public init(screenSpring: SpringConfig = .screen, startsZoomEarly: Bool = false) {
        self.screenSpring = screenSpring
        self.startsZoomEarly = startsZoomEarly
    }

    public var leadInMs: Double { startsZoomEarly ? 350 : 0 }
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

    public init(
        videoFileName: String = "recording.mov",
        videoSize: Size2,
        pointPixelScale: Double,
        durationMs: Double,
        fps: Int,
        createdAt: Date = Date()
    ) {
        self.videoFileName = videoFileName
        self.videoSize = videoSize
        self.pointPixelScale = pointPixelScale
        self.durationMs = durationMs
        self.fps = fps
        self.createdAt = createdAt
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

    public init(
        recording: RecordingInfo,
        mouseEvents: [MouseEvent],
        zooms: [ZoomRange] = [],
        style: StyleConfig = StyleConfig(),
        cursor: CursorConfig = CursorConfig(),
        animation: AnimationConfig = AnimationConfig(),
        autoZoom: AutoZoomConfig = AutoZoomConfig()
    ) {
        self.formatVersion = 1
        self.recording = recording
        self.mouseEvents = mouseEvents.sorted { $0.timeMs < $1.timeMs }
        self.zooms = zooms
        self.style = style
        self.cursor = cursor
        self.animation = animation
        self.autoZoom = autoZoom
    }

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
