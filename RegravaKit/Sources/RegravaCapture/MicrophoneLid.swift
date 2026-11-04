@preconcurrency import AVFoundation
import Foundation
import IOKit

/// Whether a microphone may be covered by a closed laptop lid: the built-in microphone, while
/// the built-in FaceTime camera is suspended (the lid is closed), on a MacBook that disconnects
/// its microphone with the lid (T2 and Apple silicon MacBooks).
public enum MicrophoneLid {
    static let builtInMicrophoneID = "BuiltInMicrophoneDevice"

    public static func mayHaveLidClosed(microphoneID: String) -> Bool {
        guard microphoneID == builtInMicrophoneID, builtInCameraIsSuspended() else { return false }
        return isT2MacBook(modelIdentifier: modelIdentifier)
    }

    /// The built-in camera is suspended while the lid is closed.
    static func builtInCameraIsSuspended() -> Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        let camera = session.devices.first { device in
            device.modelID == "FaceTime HD Camera" || (device.modelID.contains("FaceTime") && device.manufacturer == "Apple Inc.")
        }
        return camera?.isSuspended ?? false
    }

    /// The Mac's model identifier ("MacBookPro18,3", "Mac14,2").
    static let modelIdentifier: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
              let text = String(data: data, encoding: .ascii) else { return nil }
        return text.trimmingCharacters(in: .controlCharacters)
    }()

    /// A MacBook Air after 7,x, a MacBook Pro after 14,x, or a newer "MacN,M" laptop.
    static func isT2MacBook(modelIdentifier: String?) -> Bool {
        guard let model = modelIdentifier else { return false }
        if model.hasPrefix("MacBookAir") { return majorVersion(model, prefix: "MacBookAir", after: 7) }
        if model.hasPrefix("MacBookPro") { return majorVersion(model, prefix: "MacBookPro", after: 14) }
        guard let family = family(model) else { return false }
        return family == .macBookAir || family == .macBookPro
    }

    /// The number before the comma is above `after`; an empty or unreadable number counts.
    private static func majorVersion(_ model: String, prefix: String, after: Int) -> Bool {
        let digits = model.dropFirst(prefix.count).prefix { $0 != "," }
        guard !digits.isEmpty, let major = Int(digits) else { return true }
        return major > after
    }

    enum Family {
        case iMac, macMini, macBookAir, macBookPro, macBook, macPro, macStudio
    }

    static func family(_ model: String) -> Family? {
        if model.hasPrefix("iMac") { return .iMac }
        if model.hasPrefix("Macmini") { return .macMini }
        if model.hasPrefix("MacBookAir") { return .macBookAir }
        if model.hasPrefix("MacBookPro") { return .macBookPro }
        if model.hasPrefix("MacBook") { return .macBook }
        if model.hasPrefix("MacPro") { return .macPro }
        return macModels[model]
    }

    /// Models named "MacN,M".
    static let macModels: [String: Family] = [
        "Mac13,1": .macStudio, "Mac13,2": .macStudio,
        "Mac14,7": .macBookPro, "Mac14,2": .macBookAir, "Mac14,5": .macBookPro, "Mac14,9": .macBookPro,
        "Mac14,6": .macBookPro, "Mac14,10": .macBookPro, "Mac14,3": .macMini, "Mac14,12": .macMini,
        "Mac14,15": .macBookAir, "Mac14,13": .macStudio, "Mac14,14": .macStudio, "Mac14,8": .macPro,
        "Mac15,4": .iMac, "Mac15,5": .iMac, "Mac15,3": .macBookPro, "Mac15,6": .macBookPro,
        "Mac15,7": .macBookPro, "Mac15,8": .macBookPro, "Mac15,9": .macBookPro, "Mac15,10": .macBookPro,
        "Mac15,11": .macBookPro, "Mac15,12": .macBookAir, "Mac15,13": .macBookAir,
        "Mac16,1": .macBookPro, "Mac16,2": .iMac, "Mac16,3": .iMac, "Mac16,5": .macBookPro,
        "Mac16,6": .macBookPro, "Mac16,7": .macBookPro, "Mac16,8": .macBookPro,
        "Mac16,10": .macMini, "Mac16,11": .macMini,
    ]
}
