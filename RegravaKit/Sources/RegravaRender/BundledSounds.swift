import Foundation
import RegravaCore

/// The bundled sound assets (`assets/sounds`, `assets/background-audio`).
public enum BundledSounds {
    public static func click(_ set: ClickSoundSet, _ kind: ClickSoundKind) -> URL? {
        Bundle.module.url(forResource: kind.rawValue, withExtension: "wav", subdirectory: "Sounds/clicks/\(set.rawValue)")
    }

    public static var recordingBegin: URL? {
        Bundle.module.url(forResource: "begin-record", withExtension: "wav", subdirectory: "Sounds/recording")
    }

    public static var recordingEnd: URL? {
        Bundle.module.url(forResource: "end-record", withExtension: "wav", subdirectory: "Sounds/recording")
    }

    /// Built-in background tracks per category, in the dropdown order
    /// (`backgroundAudioBuiltInAssets`).
    public static let backgroundTrackNames: [String: [String]] = [
        "commercial": ["Smile Piano", "Focus Mallets", "Marimba Bed", "Product Uplift"],
        "electronic": ["Breezy House", "Ambient Electronica", "Electro Pop", "Pastel Synthwave"],
        "instrumental": ["Noble Documentary", "Corporate Smile", "Friendly Folk", "Piano Smile"],
        "lo-fi": ["Sunny Lo\u{2011}Fi", "Lean Groove", "Bright Lounge", "Cozy Chillhop", "Uplifting Sunset"],
    ]

    public static func backgroundTracks(category: String) -> [URL] {
        (backgroundTrackNames[category] ?? []).compactMap {
            Bundle.module.url(forResource: $0, withExtension: "mp3", subdirectory: "BackgroundAudio/\(category)")
        }
    }
}
