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

/// Click sound sets.
public enum ClickSoundSet: String, Codable, CaseIterable, Sendable {
    case appleMagicMouse = "apple-magic-mouse"
    case logitechMXMaster = "logitech-mx-master"

    /// Dropdown labels.
    public var label: String {
        switch self {
        case .appleMagicMouse: return "Magic Mouse™"
        case .logitechMXMaster: return "MX Master™"
        }
    }
}

/// Which file of a click set plays.
public enum ClickSoundKind: String, Sendable {
    case down, up, click
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
    /// nil = no click sound.
    public var clickSoundEffect: ClickSoundSet?
    public var clickSoundEffectVolume: Double = 0.25

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
        clickSoundEffect = c.value(.clickSoundEffect, default: d.clickSoundEffect)
        clickSoundEffectVolume = c.value(.clickSoundEffectVolume, default: d.clickSoundEffectVolume)
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

/// A click sound placed in playback time.
public struct PlannedClickSound: Equatable, Sendable {
    public var kind: ClickSoundKind
    public var sourceTimeMs: Double
    public var playbackTimeMs: Double
}

public extension Project {
    /// `planClickSounds`. Consecutive button events closer than 250 ms merge into one `click` at
    /// the first (the gap alone decides, not the event types); a longer press plays `down` then
    /// `up`. Events in cuts or in parts faster than 2× are skipped, as is anything at playback
    /// time 0 or before, and the last event never sounds.
    var plannedClickSounds: [PlannedClickSound] {
        guard audio.clickSoundEffect != nil else { return [] }
        let events = mouseEvents.filter { $0.kind == .down || $0.kind == .up }
        let resolver = self.resolver
        var consumed = Set<Int>()
        var out: [PlannedClickSound] = []
        for i in events.indices {
            guard i + 1 < events.count, !consumed.contains(i) else { continue }
            let current = events[i], next = events[i + 1]
            let t = current.timeMs
            guard resolver.isSourceTimePresent(t), resolver.speed(atSource: t) <= 2 else { continue }
            var kind: ClickSoundKind = current.kind == .down ? .down : .up
            let dt = next.timeMs - t
            if dt != 0 && dt < 250 {
                consumed.insert(i + 1)
                kind = .click
            }
            let p = resolver.sourceToPlayback(t)
            guard p > 0 else { continue }
            out.append(PlannedClickSound(kind: kind, sourceTimeMs: t, playbackTimeMs: p))
        }
        return out
    }
}

public extension ProjectStore {
    /// Folder for files copied into the project (background audio).
    static func assetsURL(bundle: URL) -> URL {
        bundle.appendingPathComponent("assets", isDirectory: true)
    }
}
