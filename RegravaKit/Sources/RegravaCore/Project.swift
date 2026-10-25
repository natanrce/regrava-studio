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

/// Glass loupe settings of a zoom (`loupeOptions`).
public struct LoupeOptions: Codable, Hashable, Sendable {
    /// Lens radius over the larger side of the recording ("Glass Loupe size", 0.25–0.75).
    public var radius01 = 0.35
    /// Bevel width over the radius.
    public var bevelRatio = 0.2
    /// Rim dispersion, 0…1.
    public var chromaticAberration = 0.5
    /// Off turns the bevel and the dispersion off.
    public var hasGlassOptics = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LoupeOptions()
        radius01 = c.value(.radius01, default: d.radius01)
        bevelRatio = c.value(.bevelRatio, default: d.bevelRatio)
        chromaticAberration = c.value(.chromaticAberration, default: d.chromaticAberration)
        hasGlassOptics = c.value(.hasGlassOptics, default: d.hasGlassOptics)
    }
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
    public var loupeOptions: LoupeOptions

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
        presentation: ZoomPresentation = .screen,
        loupeOptions: LoupeOptions = LoupeOptions()
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
        self.loupeOptions = loupeOptions
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
        loupeOptions = c.value(.loupeOptions, default: LoupeOptions())
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

/// What was recorded (`recording.mode`): a display or area, a window, or an iPhone/iPad over USB.
public enum RecordingMode: String, Codable, Sendable {
    case display, window, externalDevice
}

/// A rotation of the iPhone/iPad during the recording (`-changes.json` records): frames are
/// rotated back to the first frame's size from `timeMs` on.
public struct DeviceOrientationChange: Codable, Hashable, Sendable {
    public enum Animation: String, Codable, Sendable { case instant, clockwise, counterClockwise }
    public var timeMs: Double
    public var contentRect: Rect2
    public var videoRotationAngleForHorizontalLevel: Double
    public var animation: Animation

    public init(timeMs: Double, contentRect: Rect2, videoRotationAngleForHorizontalLevel: Double, animation: Animation) {
        self.timeMs = timeMs
        self.contentRect = contentRect
        self.videoRotationAngleForHorizontalLevel = videoRotationAngleForHorizontalLevel
        self.animation = animation
    }
}

/// The iPhone/iPad of an external-device recording (`ExternalDevice`).
public struct ExternalDeviceInfo: Codable, Hashable, Sendable {
    public var deviceId: String
    /// "Tom's iPhone".
    public var name: String
    /// "iPhone17,1".
    public var modelId: String?
    public var modelMarketingName: String?
    public var orientationChanges: [DeviceOrientationChange]

    public init(deviceId: String, name: String, modelId: String? = nil, modelMarketingName: String? = nil, orientationChanges: [DeviceOrientationChange] = []) {
        self.deviceId = deviceId
        self.name = name
        self.modelId = modelId
        self.modelMarketingName = modelMarketingName
        self.orientationChanges = orientationChanges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = c.value(.deviceId, default: "")
        name = c.value(.name, default: "External Device")
        modelId = c.value(.modelId, default: nil)
        modelMarketingName = c.value(.modelMarketingName, default: nil)
        orientationChanges = c.value(.orientationChanges, default: [])
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
    public var mode: RecordingMode
    /// Set for `.externalDevice` recordings.
    public var externalDevice: ExternalDeviceInfo?
    /// `recordingFlags` ("ScreenContinuity" for iPhone Mirroring windows).
    public var flags: [String]
    /// Where each recording session after the first starts (a resume after a pause), recording ms.
    public var sessionStartsMs: [Double] = []

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
        cameraSize: Size2? = nil,
        mode: RecordingMode = .display,
        externalDevice: ExternalDeviceInfo? = nil,
        flags: [String] = []
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
        self.mode = mode
        self.externalDevice = externalDevice
        self.flags = flags
    }

    /// `isScreenContinuityRecording`: an iPhone Mirroring window.
    public var isScreenContinuity: Bool { flags.contains("ScreenContinuity") }

    public var hasCamera: Bool { cameraFileName != nil }
    public var isExternalDeviceMode: Bool { mode == .externalDevice }
    public var hasExternalDeviceAudio: Bool { audioSources.contains(.externalDevice) }

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
        mode = c.value(.mode, default: .display)
        externalDevice = c.value(.externalDevice, default: nil)
        flags = c.value(.flags, default: [])
        sessionStartsMs = c.value(.sessionStartsMs, default: [])
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
    /// Key presses and releases (`recording.keystrokes`).
    public var keystrokes: [Keystroke]
    /// Clips in source order (`scene.slices`).
    public var slices: [Slice]
    /// Sensitive data and highlight masks (`scene.masks`).
    public var masks: [MaskRange] = []
    /// Hide sensitive data / Hide faces (`processing`).
    public var processing = ProcessingConfig()
    public var audio = AudioConfig()
    /// Device frame around iPhone/iPad recordings (`device`).
    public var device = DeviceConfig()
    /// The recorded area kept on screen (`crop`).
    public var crop = ScreenCropConfig()
    /// Camera image settings (`cameraConfig`).
    public var camera = CameraConfig()
    public var captions = CaptionsConfig()
    /// Layout used where no layout range applies (`defaultLayout`).
    public var defaultLayout = DefaultCameraLayout()
    /// Camera layout ranges in source time (`scene.layouts`).
    public var cameraLayouts: [CameraLayoutRange] = []
    /// Start times of "Speed up typing" suggestions that were applied or removed
    /// (`resolved-typing-speed-increase-suggestions-v2`).
    public var resolvedTypingSuggestionsMs: [Double] = []
    /// Set on every save (`lastSavedAt`); a new recording never saved has none.
    public var lastSavedAt: Date?

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
        processing = c.value(.processing, default: ProcessingConfig())
        audio = c.value(.audio, default: AudioConfig())
        device = c.value(.device, default: DeviceConfig())
        crop = c.value(.crop, default: ScreenCropConfig())
        lastSavedAt = c.value(.lastSavedAt, default: nil)
        camera = c.value(.camera, default: CameraConfig())
        captions = c.value(.captions, default: CaptionsConfig())
        defaultLayout = c.value(.defaultLayout, default: DefaultCameraLayout())
        cameraLayouts = c.value(.cameraLayouts, default: [])
    }

    /// Output canvas size in pixels (aspect ratio from `style`).
    public var canvasSize: Size2 { StyleConfig.canvasSize(aspectRatio: stageAspectRatio) }

    /// Replaces generated zooms with a fresh set derived from the clicks, keeping user-made ones.
    public mutating func regenerateAutomaticZooms() {
        // iPhone/iPad recordings have no automatic zooms (`useAutomaticZooms`).
        let generated = recording.isExternalDeviceMode ? [] : AutoZoomGenerator.generate(
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
