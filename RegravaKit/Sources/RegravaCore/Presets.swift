import Foundation

/// The project's settings, as saved in a preset (`presetConfig` = `projectConfig.serialize()`).
public struct PresetConfig: Codable, Hashable, Sendable {
    public var style: StyleConfig
    public var cursor: CursorConfig
    public var animation: AnimationConfig
    public var audio: AudioConfig

    public init(style: StyleConfig, cursor: CursorConfig, animation: AnimationConfig, audio: AudioConfig) {
        self.style = style
        self.cursor = cursor
        self.animation = animation
        self.audio = audio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, default: StyleConfig())
        cursor = c.value(.cursor, default: CursorConfig())
        animation = c.value(.animation, default: AnimationConfig())
        audio = c.value(.audio, default: AudioConfig())
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
        PresetConfig(style: style, cursor: cursor, animation: animation, audio: audio)
    }

    /// `updateConfig(preset.projectConfig)`.
    mutating func apply(_ config: PresetConfig) {
        style = config.style
        cursor = config.cursor
        animation = config.animation
        audio = config.audio
    }
}
