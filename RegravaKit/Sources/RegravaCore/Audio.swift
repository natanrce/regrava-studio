import Foundation

/// Where an audio track of the recording comes from (microphone / system-audio).
public enum AudioSource: String, Codable, Sendable {
    case microphone
    case systemAudio = "system-audio"
    /// The iPhone/iPad's own audio (`external-device`).
    case externalDevice = "external-device"
}

/// Microphone processing modes; stored, not processed yet.
public enum MicrophoneAudioPreset: String, Codable, CaseIterable, Sendable {
    case channelFix = "channel-fix"
    case voice
    case loud
    case noiseReduction = "noise-reduction"
    case podcast
}

/// `audioConfig`.
public struct AudioConfig: Codable, Hashable, Sendable {
    public var volume: Double = 1
    public var muteMicrophone = false
    public var microphoneAudioPreset: MicrophoneAudioPreset = .voice
    public var muteSystemAudio = false
    public var muteExternalDeviceAudio = false
    /// File in the project's assets folder.
    public var backgroundAudioFileName: String?
    public var backgroundAudioVolume: Double = 0.05
    public var muteBackgroundAudio = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioConfig()
        volume = c.value(.volume, default: d.volume)
        muteMicrophone = c.value(.muteMicrophone, default: d.muteMicrophone)
        microphoneAudioPreset = c.value(.microphoneAudioPreset, default: d.microphoneAudioPreset)
        muteSystemAudio = c.value(.muteSystemAudio, default: d.muteSystemAudio)
        muteExternalDeviceAudio = c.value(.muteExternalDeviceAudio, default: d.muteExternalDeviceAudio)
        backgroundAudioFileName = c.value(.backgroundAudioFileName, default: d.backgroundAudioFileName)
        backgroundAudioVolume = c.value(.backgroundAudioVolume, default: d.backgroundAudioVolume)
        muteBackgroundAudio = c.value(.muteBackgroundAudio, default: d.muteBackgroundAudio)
    }

    public func isMuted(_ source: AudioSource) -> Bool {
        switch source {
        case .microphone: return muteMicrophone
        case .systemAudio: return muteSystemAudio
        case .externalDevice: return muteExternalDeviceAudio
        }
    }
}

public extension Slice {
    /// Clip volume for a source.
    func volume(for source: AudioSource) -> Double {
        switch source {
        case .microphone: return volume
        case .systemAudio: return systemAudioVolume
        case .externalDevice: return externalDeviceAudioVolume
        }
    }
}

public extension ProjectStore {
    /// Folder for files copied into the project (background audio).
    static func assetsURL(bundle: URL) -> URL {
        bundle.appendingPathComponent("assets", isDirectory: true)
    }
}
