import Foundation

/// The project's settings, as saved in a preset (`presetConfig` = `projectConfig.serialize()`).
public struct PresetConfig: Codable, Hashable, Sendable {
    public var style: StyleConfig
    public var cursor: CursorConfig
    public var animation: AnimationConfig
    public var audio: AudioConfig
    /// The rest of the `presetConfig` (nil in presets saved before they were kept).
    public var camera: CameraConfig?
    public var captions: CaptionsConfig?
    public var processing: ProcessingConfig?
    public var defaultLayout: DefaultCameraLayout?
    public var device: DeviceConfig?

    public init(style: StyleConfig, cursor: CursorConfig, animation: AnimationConfig, audio: AudioConfig,
                camera: CameraConfig? = nil, captions: CaptionsConfig? = nil, processing: ProcessingConfig? = nil,
                defaultLayout: DefaultCameraLayout? = nil, device: DeviceConfig? = nil) {
        self.style = style
        self.cursor = cursor
        self.animation = animation
        self.audio = audio
        self.camera = camera
        self.captions = captions
        self.processing = processing
        self.defaultLayout = defaultLayout
        self.device = device
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, default: StyleConfig())
        cursor = c.value(.cursor, default: CursorConfig())
        animation = c.value(.animation, default: AnimationConfig())
        audio = c.value(.audio, default: AudioConfig())
        camera = c.value(.camera, default: nil)
        captions = c.value(.captions, default: nil)
        processing = c.value(.processing, default: nil)
        defaultLayout = c.value(.defaultLayout, default: nil)
        device = c.value(.device, default: nil)
    }

    /// Files the settings refer to (background image, background audio), stored in a preset
    /// next to its config and in a project's assets folder.
    public var assetFileNames: [String] {
        [style.background.imageFileName, audio.backgroundAudioFileName].compactMap { $0 }
    }
}

/// A saved preset.
public struct Preset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var config: PresetConfig

    public init(id: UUID = UUID(), name: String, config: PresetConfig) {
        self.id = id
        self.name = name
        self.config = config
    }
}

public extension Project {
    var presetConfig: PresetConfig {
        PresetConfig(style: style, cursor: cursor, animation: animation, audio: audio, camera: camera, captions: captions,
                     processing: processing, defaultLayout: defaultLayout, device: device)
    }

    /// `updateConfig(preset.projectConfig)`.
    mutating func apply(_ config: PresetConfig) {
        style = config.style
        cursor = config.cursor
        animation = config.animation
        audio = config.audio
        if let preset = config.camera {
            // The camera's look; its crop and delay belong to the recording.
            camera.hide = preset.hide
            camera.mirror = preset.mirror
            camera.aspectRatio = preset.aspectRatio
            camera.enableFaceTracking = preset.enableFaceTracking
            camera.hideDuringSilenceMs = preset.hideDuringSilenceMs
            camera.lut = preset.lut
            camera.lutIntensity = preset.lutIntensity
            camera.grain = preset.grain
            camera.sharpen01 = preset.sharpen01
            camera.background.blurAmount01 = preset.background.blurAmount01
            camera.background.edgeFalloff01 = preset.background.edgeFalloff01
        }
        if let preset = config.captions { captions = preset }
        if let preset = config.processing { processing = preset }
        if let preset = config.defaultLayout { defaultLayout = preset }
        if let preset = config.device { device = preset }
    }
}
