import Foundation

// The microphone audio modes: each is a fixed chain of processors the take is rendered
// through once, offline, into `cache/audio-render`.

/// One step of a chain.
public enum AudioProcessor: Hashable, Sendable {
    public enum AppleUnit: String, Hashable, Sendable {
        /// `aufx/hpas/appl`.
        case highPass = "hpas"
        /// `aufx/dcmp/appl`.
        case dynamicsProcessor = "dcmp"
        /// `aufx/lmtr/appl`.
        case peakLimiter = "lmtr"
        /// `aufx/filt/appl`.
        case multibandFilter = "filt"
    }

    /// Sounds kept by `keep` (`KeptSounds`).
    public struct KeptSounds: Hashable, Sendable {
        public var speechLabels: [String]
        public var speechConfidence: Double
        public var nearSpeechLabels: [String]
        public var nearSpeechConfidence: Double
        public var nearSpeechWithinMs: Double
        public var shortestCutMs: Double
    }

    case resample(sampleRate: Double)
    /// Peak to `peakDb` (nil keeps the level); a channel `silentChannelBelowDb` under the other
    /// becomes a copy of it.
    case normalize(peakDb: Double?, silentChannelBelowDb: Double)
    /// An Apple AudioUnit with its knobs by parameter address.
    case audioUnit(AppleUnit, params: [Int: Double])
    case leveler(targetDb: Double, holdBelowSpeechDb: Double, floorDb: Double, gainRangeDb: ClosedRange<Double>, windowMs: Double, lookMs: Double, fallMs: Double, riseMs: Double)
    case keep(sounds: KeptSounds, fadeMs: Double?, pauseDb: Double?)
    case matchEq(target: [Double], correctionDb: ClosedRange<Double>)
    case dynamicEq(frame: Int, detectorHz: ClosedRange<Double>, referenceHz: ClosedRange<Double>?, allowedDb: Double, ratio: Double, maxCutDb: Double, cutHz: ClosedRange<Double>, taperOctaves: Double, attackMs: Double, releaseMs: Double)
    case restoreSibilance
    case tfRestormer(bandEndsBelowPeakDb: Double, pauseBelowSpeechDb: Double, pauseLevelDb: ClosedRange<Double>, shortestSilenceMs: Double, keptAroundSpeechMs: Double, fadeMs: Double)
    case mossFormer2

    /// Runs in the speech-models service.
    public var needsSpeechModels: Bool {
        switch self {
        case .tfRestormer, .mossFormer2: return true
        default: return false
        }
    }
}

public extension MicrophoneAudioPreset {
    /// Segmented control labels and descriptions.
    var label: String {
        switch self {
        case .channelFix: return "Off"
        case .voice: return "Standard"
        case .loud: return "Loud"
        case .noiseReduction: return "Noise reduction"
        case .podcast: return "Podcast"
        }
    }

    var detail: String {
        switch self {
        case .channelFix: return "Plays your microphone as recorded."
        case .voice: return "Adjusts your voice to a consistent volume. Its character stays the same."
        case .loud: return "Boosts your voice to a consistent, loud volume."
        case .noiseReduction: return "Boosts your voice and reduces background noise and room echo."
        case .podcast: return "Gives your voice the depth and clarity of a studio recording. Experimental."
        }
    }

    var badge: String? { self == .podcast ? "Beta" : nil }

    /// The task's label while it renders.
    var taskLabel: String {
        switch self {
        case .channelFix, .voice: return "Preparing audio"
        case .loud: return "Leveling audio"
        case .noiseReduction: return "Reducing noise"
        case .podcast: return "Generating podcast audio"
        }
    }

    /// The chain's hash, which names its file.
    var chainHash: String {
        switch self {
        case .voice: return "iX1Wu7lsa1zS0Vx0oTNIwXFWSN7IypT2"
        case .channelFix: return "0nX8ydHM6lZGqXj4gX1U6RlOk9dikdT2"
        case .loud: return "UprM0ljWAnpukNnyKt9m09tmapVMeBza"
        case .noiseReduction: return "3w8jfgu7lgMxVicnNkWVPoWF7MsxnyCX"
        case .podcast: return "mT900RlEWpNGcrbQK3LGu39kszVAaNhI"
        }
    }

    var needsSpeechModels: Bool { chain.contains { $0.needsSpeechModels } }

    var chain: [AudioProcessor] {
        typealias P = AudioProcessor
        let normalize = P.normalize(peakDb: -6, silentChannelBelowDb: 30)
        let strict = P.KeptSounds(
            speechLabels: ["speech", "whispering", "shout", "yell", "singing", "rapping"],
            speechConfidence: 0.25,
            nearSpeechLabels: ["sigh", "humming", "laughter", "cough", "breathing", "gasp", "screaming", "sneeze", "chuckle_chortle", "crying_sobbing", "babble"],
            nearSpeechConfidence: 0.35,
            nearSpeechWithinMs: 1500,
            shortestCutMs: 3000
        )
        var loose = strict
        loose.speechConfidence = 0.1
        loose.shortestCutMs = 1000
        let loudTail: [P] = [
            .leveler(targetDb: -16, holdBelowSpeechDb: 35, floorDb: -60, gainRangeDb: -20...30, windowMs: 400, lookMs: 50, fallMs: 150, riseMs: 400),
            .audioUnit(.highPass, params: [0: 70, 1: 0]),
            .audioUnit(.dynamicsProcessor, params: [0: -40, 1: 4, 2: 2, 3: -50, 4: 0.005, 5: 0.12, 6: 25]),
            .audioUnit(.peakLimiter, params: [0: 0.001, 1: 0.05, 2: 0]),
            .keep(sounds: loose, fadeMs: 400, pauseDb: -20),
        ]
        switch self {
        case .channelFix:
            return [.resample(sampleRate: 48000), .normalize(peakDb: nil, silentChannelBelowDb: 30)]
        case .voice:
            return [.resample(sampleRate: 48000), normalize]
        case .loud:
            return [.resample(sampleRate: 48000), normalize] + loudTail
        case .noiseReduction:
            return [.resample(sampleRate: 48000), normalize, .mossFormer2] + loudTail
        case .podcast:
            let target: [Double] = [-15.3, -1.3, 4.6, 5.9, 4.7, 7.7, 6.7, 6, 6.2, 8.2, 6.9, 4.3, 2, 2, -0.2, -4.3, -3.9, -6.9, -8.2, -7.3, -8.9, -7.8, -12.1, -20, -29.1]
            return [
                .resample(sampleRate: 48000),
                normalize,
                .keep(sounds: strict, fadeMs: nil, pauseDb: nil),
                .tfRestormer(bandEndsBelowPeakDb: 60, pauseBelowSpeechDb: 30, pauseLevelDb: -75...(-45), shortestSilenceMs: 400, keptAroundSpeechMs: 300, fadeMs: 10),
                .restoreSibilance,
                .matchEq(target: target, correctionDb: -15...12),
                .dynamicEq(frame: 2048, detectorHz: 250...500, referenceHz: 1000...4000, allowedDb: 7.5, ratio: .greatestFiniteMagnitude, maxCutDb: 4, cutHz: 200...650, taperOctaves: 0.4, attackMs: 15, releaseMs: 80),
                .leveler(targetDb: -18, holdBelowSpeechDb: 20, floorDb: -68, gainRangeDb: -30...30, windowMs: 1000, lookMs: 50, fallMs: 800, riseMs: 2000),
                .dynamicEq(frame: 1024, detectorHz: 5000...9000, referenceHz: nil, allowedDb: -23, ratio: 4, maxCutDb: 8, cutHz: 3500...12500, taperOctaves: 0.3, attackMs: 1, releaseMs: 50),
                .audioUnit(.highPass, params: [0: 70, 1: 0]),
                .audioUnit(.multibandFilter, params: [3: 4000, 4: -3, 5: 0.3]),
                .audioUnit(.peakLimiter, params: [0: 0.002, 1: 0.1, 2: 0]),
            ]
        }
    }

    /// `<take>.<hash>.m4a` under `cache/audio-render`.
    func renderFileName(take: String) -> String { "\(take).\(chainHash).m4a" }
}

public extension ProjectStore {
    static func audioRenderURL(bundle: URL, preset: MicrophoneAudioPreset) -> URL {
        bundle.appendingPathComponent("cache/audio-render", isDirectory: true).appendingPathComponent(preset.renderFileName(take: "microphone"))
    }
}
