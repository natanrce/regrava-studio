import Foundation

// Device frames (mockups) around iPhone/iPad recordings: the catalog, its aspect matching
// and settings.

/// One device model of the catalog, in device points.
public struct DeviceFrame: Hashable, Sendable {
    public var name: String
    /// First = default; empty for a single uncoloured image.
    public var colors: [String]
    /// The frame image size: the body used for layout.
    public var width: Double
    public var height: Double
    /// The screen hole inside the frame.
    public var screenX: Double
    public var screenY: Double
    public var screenWidth: Double
    public var screenHeight: Double
    public var screenBorderRadius: Double?
    public var frameBorderRadius: Double?
    public var frameBorderRoundness: Double?
    public var frameBodyInset: Double?

    static let bodyRadiusScale = 1.04

    /// The video's corner radius inside the hole.
    public var screenRadius: Double { screenBorderRadius ?? 0 }
    /// The body's corner radius.
    public var bodyRadius: Double { (frameBorderRadius ?? screenRadius + min(screenX, screenY)) * Self.bodyRadiusScale }
    /// Corner smoothing of the body.
    public var roundness: Double { frameBorderRoundness ?? 1 }
    /// How far the shadow caster shrinks inside the body.
    public var bodyInset: Double { frameBodyInset ?? 0 }

    /// `videoRegion01`: the hole over the body.
    public var videoRegion01: Rect2 {
        Rect2(x: screenX / width, y: screenY / height, width: screenWidth / width, height: screenHeight / height)
    }

    /// "<name> <color>", or the name alone; also the image's file name.
    public func key(_ color: String?) -> String {
        guard !colors.isEmpty else { return name }
        return name + " " + (color ?? colors[0])
    }
}

/// A chosen device and colour.
public struct ResolvedDeviceFrame: Hashable, Sendable {
    public var device: DeviceFrame
    public var color: String?
    public var key: String { device.key(color) }
}

/// `device`.
public struct DeviceConfig: Codable, Hashable, Sendable {
    /// "Use device mockup".
    public var enableMockup = true
    /// nil = chosen automatically from the recording's aspect (not saved).
    public var frameKey: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableMockup = c.value(.enableMockup, default: true)
        frameKey = c.value(.frameKey, default: nil)
    }
}

public enum DeviceFrames {
    /// Catalog order matters: ties keep it.
    public static let catalog: [DeviceFrame] = [
        DeviceFrame(name: "iPhone 18 Pro Max", colors: ["Black", "Silver", "Glacier", "Burgundy"], width: 475.5, height: 983.8, screenX: 17.8, screenY: 13.9, screenWidth: 440, screenHeight: 956, screenBorderRadius: 60, frameBorderRadius: 78.4, frameBorderRoundness: 0.6, frameBodyInset: 3.5),
        DeviceFrame(name: "iPhone 18 Pro", colors: ["Black", "Silver", "Glacier", "Burgundy"], width: 438.8, height: 903.3, screenX: 18.4, screenY: 14.7, screenWidth: 402, screenHeight: 874, screenBorderRadius: 58, frameBorderRadius: 78.4, frameBorderRoundness: 0.6, frameBodyInset: 3.5),
        DeviceFrame(name: "iPhone 17 Pro Max", colors: ["Silver", "Cosmic Orange", "Deep Blue"], width: 462, height: 978, screenX: 14.5, screenY: 13, screenWidth: 434, screenHeight: 951, screenBorderRadius: 66, frameBorderRadius: 75.3, frameBorderRoundness: 0.6, frameBodyInset: 2),
        DeviceFrame(name: "iPhone 17 Pro", colors: ["Black", "White", "Gray", "Dark Blue", "Orange"], width: 424, height: 896, screenX: 17, screenY: 16, screenWidth: 390, screenHeight: 863, screenBorderRadius: 63.1, frameBorderRadius: 75.9, frameBorderRoundness: 0.6, frameBodyInset: 2),
        DeviceFrame(name: "iPhone Air", colors: ["Black", "White", "Light Gold", "Light Blue"], width: 455, height: 945, screenX: 17, screenY: 16, screenWidth: 420, screenHeight: 912, screenBorderRadius: 63.1, frameBorderRadius: 75.9, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 16 Pro Max", colors: ["Black", "White", "Natural", "Desert"], width: 471, height: 986, screenX: 17, screenY: 16, screenWidth: 437, screenHeight: 953, screenBorderRadius: 63.1, frameBorderRadius: 75.9, frameBorderRoundness: 0.6, frameBodyInset: 2),
        DeviceFrame(name: "iPhone 16 Plus", colors: ["Black", "White", "Natural", "Desert"], width: 461, height: 962, screenX: 17, screenY: 16, screenWidth: 427, screenHeight: 929, screenBorderRadius: 63.1, frameBorderRadius: 75.9, frameBorderRoundness: 0.6, frameBodyInset: 2),
        DeviceFrame(name: "iPhone 16 Pro", colors: ["Black", "White", "Natural", "Desert"], width: 434, height: 904, screenX: 17, screenY: 16, screenWidth: 400, screenHeight: 871, screenBorderRadius: 63.1, frameBorderRadius: 75.9, frameBorderRoundness: 0.6, frameBodyInset: 2),
        DeviceFrame(name: "iPhone 16", colors: ["Black", "White", "Teal", "Pink", "Ultramarine"], width: 433, height: 875, screenX: 20, screenY: 19, screenWidth: 393, screenHeight: 836, screenBorderRadius: 60.1, frameBorderRadius: 75.9, frameBorderRoundness: 0.6, frameBodyInset: 2),
        DeviceFrame(name: "iPhone 15 Pro Max", colors: ["Black Titanium", "White Titanium", "Natural Titanium", "Blue Titanium"], width: 467, height: 963, screenX: 19.5, screenY: 16.5, screenWidth: 428, screenHeight: 930, screenBorderRadius: 55.1, frameBorderRadius: 72, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 15 Plus", colors: ["Black", "Blue", "Green", "Pink", "Yellow"], width: 478, height: 972, screenX: 25, screenY: 21, screenWidth: 428, screenHeight: 930, screenBorderRadius: 55.2, frameBorderRadius: 74.9, frameBorderRoundness: 0.6, frameBodyInset: 4),
        DeviceFrame(name: "iPhone 15 Pro", colors: ["Black Titanium", "White Titanium", "Natural Titanium", "Blue Titanium"], width: 430, height: 883, screenX: 19, screenY: 16, screenWidth: 392, screenHeight: 851, screenBorderRadius: 55.7, frameBorderRadius: 71.9, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 15", colors: ["Black", "Blue", "Green", "Pink", "Yellow"], width: 441, height: 892, screenX: 25, screenY: 21, screenWidth: 391, screenHeight: 850, screenBorderRadius: 55.2, frameBorderRadius: 74.9, frameBorderRoundness: 0.6, frameBodyInset: 4),
        DeviceFrame(name: "iPhone 14 Pro Max", colors: ["Deep Purple", "Gold", "Silver", "Space Black"], width: 473, height: 968, screenX: 21.5, screenY: 18, screenWidth: 430, screenHeight: 932, screenBorderRadius: 56.2, frameBorderRadius: 75, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 14 Pro", colors: ["Deep Purple", "Gold", "Silver", "Space Black"], width: 438, height: 891, screenX: 22.5, screenY: 19.5, screenWidth: 393, screenHeight: 852, screenBorderRadius: 56.2, frameBorderRadius: 75.1, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 14", colors: ["Midnight", "Starlight", "(Product) Red", "Blue", "Purple", "Yellow"], width: 438, height: 886, screenX: 24, screenY: 21, screenWidth: 390, screenHeight: 844, screenBorderRadius: 47.1, frameBorderRadius: 67.9, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 13 Pro Max", colors: ["Alpine Green", "Silver", "Gold", "Graphite", "Sierra Blue"], width: 476, height: 968, screenX: 24, screenY: 21, screenWidth: 428, screenHeight: 926, screenBorderRadius: 47.1, frameBorderRadius: 68.1, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 13 Pro", colors: ["Alpine Green", "Silver", "Gold", "Graphite", "Sierra Blue"], width: 438, height: 886, screenX: 24, screenY: 21, screenWidth: 390, screenHeight: 844, screenBorderRadius: 47.1, frameBorderRadius: 68.1, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 13 Mini", colors: ["Green", "Pink", "Blue", "Midnight", "Starlight", "(PRODUCT)RED"], width: 408, height: 822, screenX: 24, screenY: 21, screenWidth: 360, screenHeight: 780, screenBorderRadius: 47.1, frameBorderRadius: 67.9, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 13", colors: ["Green", "Pink", "Blue", "Midnight", "Starlight", "(PRODUCT)RED"], width: 438, height: 886, screenX: 24, screenY: 21, screenWidth: 390, screenHeight: 844, screenBorderRadius: 47.1, frameBorderRadius: 67.9, frameBorderRoundness: 0.6, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 12 Pro Max", colors: [], width: 423, height: 858, screenX: 22, screenY: 19, screenWidth: 379, screenHeight: 820, screenBorderRadius: 47.1, frameBorderRadius: 65, frameBorderRoundness: 0.4, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 12 Pro", colors: [], width: 432, height: 858, screenX: 22, screenY: 19, screenWidth: 379, screenHeight: 820, screenBorderRadius: 50, frameBorderRadius: nil, frameBorderRoundness: nil, frameBodyInset: nil),
        DeviceFrame(name: "iPhone 12 Mini", colors: [], width: 423, height: 858, screenX: 22, screenY: 19, screenWidth: 379, screenHeight: 820, screenBorderRadius: 47.1, frameBorderRadius: 65, frameBorderRoundness: 0.4, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 12", colors: ["Black", "White", "Green", "Purple", "Blue", "(PRODUCT)RED"], width: 423, height: 858, screenX: 22, screenY: 19, screenWidth: 379, screenHeight: 820, screenBorderRadius: 47.1, frameBorderRadius: 65, frameBorderRoundness: 0.4, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 11 Pro", colors: [], width: 427, height: 858, screenX: 26, screenY: 23, screenWidth: 375, screenHeight: 812, screenBorderRadius: 38.1, frameBorderRadius: 62.9, frameBorderRoundness: 0, frameBodyInset: 3),
        DeviceFrame(name: "iPhone 11", colors: ["Black"], width: 466, height: 942, screenX: 29, screenY: 26, screenWidth: 408, screenHeight: 890, screenBorderRadius: 41.5, frameBorderRadius: 68.9, frameBorderRoundness: 0, frameBodyInset: 3.5),
        DeviceFrame(name: "iPhone SE", colors: ["Midnight", "Starlight", "(PRODUCT)RED"], width: 427, height: 858, screenX: 26, screenY: 95, screenWidth: 375, screenHeight: 667, screenBorderRadius: 0.6, frameBorderRadius: 62.9, frameBorderRoundness: 0, frameBodyInset: 3),
        DeviceFrame(name: "MacBook Air", colors: [], width: 2011, height: 1180, screenX: 226, screenY: 72, screenWidth: 1559, screenHeight: 975, screenBorderRadius: 0.4, frameBorderRadius: 56.8, frameBorderRoundness: 0.6, frameBodyInset: nil),
        DeviceFrame(name: "MacBook Pro 15-inch", colors: [], width: 2011, height: 1171, screenX: 233, screenY: 68, screenWidth: 1545, screenHeight: 966, screenBorderRadius: 0.4, frameBorderRadius: 47.8, frameBorderRoundness: 0.6, frameBodyInset: nil),
        DeviceFrame(name: "MacBook Pro 16-inch", colors: [], width: 2110, height: 1286, screenX: 191, screenY: 27, screenWidth: 1728, screenHeight: 1117, screenBorderRadius: 0.4, frameBorderRadius: 46, frameBorderRoundness: 0, frameBodyInset: nil),
        DeviceFrame(name: "MacBook Air M2", colors: ["Midnight", "Silver", "Space Gray", "Starlight"], width: 1624, height: 969, screenX: 172, screenY: 30, screenWidth: 1280, screenHeight: 832, screenBorderRadius: 0.4, frameBorderRadius: 46.8, frameBorderRoundness: 0.6, frameBodyInset: nil),
        DeviceFrame(name: "iPad", colors: ["Space Gray"], width: 625, height: 900, screenX: 25, screenY: 66, screenWidth: 575, screenHeight: 767, screenBorderRadius: 0.4, frameBorderRadius: 34.9, frameBorderRoundness: 0, frameBodyInset: nil),
        DeviceFrame(name: "iPad Mini", colors: ["Space Gray", "Pink", "Purple", "Starlight"], width: 700, height: 1019, screenX: 46, screenY: 48, screenWidth: 608, screenHeight: 926, screenBorderRadius: 20.1, frameBorderRadius: 65, frameBorderRoundness: 0, frameBodyInset: nil),
        DeviceFrame(name: "iPad Pro 11", colors: ["Space Gray"], width: 651, height: 902, screenX: 34, screenY: 36, screenWidth: 581, screenHeight: 832, screenBorderRadius: 0.4, frameBorderRadius: 45.9, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Air 4", colors: [], width: 651, height: 902, screenX: 38, screenY: 40, screenWidth: 573, screenHeight: 824, screenBorderRadius: 13.2, frameBorderRadius: 45.9, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Air 5th Gen", colors: ["Space Gray", "Pink", "Purple", "Blue", "Starlight"], width: 930, height: 1291, screenX: 54, screenY: 57, screenWidth: 820, screenHeight: 1180, screenBorderRadius: 19.1, frameBorderRadius: 65, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Pro 12", colors: ["Space Gray", "Silver"], width: 690, height: 902, screenX: 36, screenY: 36, screenWidth: 616, screenHeight: 832, screenBorderRadius: 8, frameBorderRadius: 47.3, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Pro 12 Horizontal", colors: ["Space Gray", "Silver"], width: 902, height: 690, screenX: 36, screenY: 38, screenWidth: 832, screenHeight: 616, screenBorderRadius: 8, frameBorderRadius: 46.8, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Horizontal", colors: ["Space Gray"], width: 900, height: 625, screenX: 66, screenY: 25, screenWidth: 767, screenHeight: 575, screenBorderRadius: 0.4, frameBorderRadius: 34.9, frameBorderRoundness: 0, frameBodyInset: nil),
        DeviceFrame(name: "iPad Mini Horizontal", colors: ["Space Gray", "Pink", "Purple", "Starlight"], width: 1019, height: 700, screenX: 48, screenY: 46, screenWidth: 926, screenHeight: 608, screenBorderRadius: 20.1, frameBorderRadius: 65, frameBorderRoundness: 0, frameBodyInset: nil),
        DeviceFrame(name: "iPad Pro 11 Horizontal", colors: ["Space Gray"], width: 902, height: 651, screenX: 36, screenY: 36, screenWidth: 832, screenHeight: 581, screenBorderRadius: 0.4, frameBorderRadius: 45.9, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Air 4 Horizontal", colors: [], width: 902, height: 651, screenX: 40, screenY: 40, screenWidth: 824, screenHeight: 573, screenBorderRadius: 13.2, frameBorderRadius: 45.9, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Air 5th Gen Horizontal", colors: ["Space Gray", "Pink", "Purple", "Blue", "Starlight"], width: 1291.5, height: 930.5, screenX: 57.5, screenY: 56.5, screenWidth: 1180, screenHeight: 820, screenBorderRadius: 19.1, frameBorderRadius: 63.8, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Pro 11 M4", colors: ["Space Black", "Silver"], width: 935, height: 1301, screenX: 50, screenY: 51, screenWidth: 834.5, screenHeight: 1200, screenBorderRadius: 11.2, frameBorderRadius: 65.8, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iPad Pro 11 M4 Horizontal", colors: ["Space Black", "Silver"], width: 1301, height: 965, screenX: 51, screenY: 52.5, screenWidth: 1200, screenHeight: 861.5, screenBorderRadius: 11.7, frameBorderRadius: 66.7, frameBorderRoundness: 0, frameBodyInset: 2),
        DeviceFrame(name: "iMac 24-inch", colors: ["Blue", "Green", "Orange", "Pink", "Purple", "Silver", "Yellow"], width: 1180, height: 995, screenX: 30, screenY: 30, screenWidth: 1120, screenHeight: 630, screenBorderRadius: 0.4, frameBorderRadius: 17, frameBorderRoundness: 0, frameBodyInset: nil),
    ]

    /// The device and colour of a key.
    public static func lookup(_ key: String) -> ResolvedDeviceFrame? {
        for device in catalog {
            if device.colors.isEmpty {
                if device.name == key { return ResolvedDeviceFrame(device: device, color: nil) }
            } else if let color = device.colors.first(where: { device.key($0) == key }) {
                return ResolvedDeviceFrame(device: device, color: color)
            }
        }
        return nil
    }

    /// Aspect difference rounded to 0.001.
    public static func aspectDistance(_ size: Size2, _ device: DeviceFrame) -> Double {
        let d = abs(size.width / max(size.height, 0.0001) - device.screenWidth / device.screenHeight)
        return (d / 0.001).rounded() * 0.001
    }

    /// Devices within `tolerance`, closest first (stable) or in catalog order.
    public static func candidates(_ size: Size2, tolerance: Double, sorted: Bool = true) -> [DeviceFrame] {
        let list = sorted
            ? catalog.enumerated().sorted { (aspectDistance(size, $0.element), $0.offset) < (aspectDistance(size, $1.element), $1.offset) }.map(\.element)
            : catalog
        return list.filter { aspectDistance(size, $0) <= tolerance + 1e-9 }
    }
}

public extension Project {
    /// `canHaveDeviceFrame`: iPhone/iPad and iPhone Mirroring recordings.
    var canHaveDeviceFrame: Bool { recording.isExternalDeviceMode || recording.isScreenContinuity }

    /// `isUsingDeviceFrame`.
    var isUsingDeviceFrame: Bool { canHaveDeviceFrame && device.enableMockup }

    /// The recorded screen size compared with the catalog.
    var deviceScreenSize: Size2 { recording.videoSize }

    /// The saved choice, else the first device within 0.1 of the recording's aspect.
    var resolvedDeviceFrame: ResolvedDeviceFrame? {
        guard canHaveDeviceFrame else { return nil }
        if let key = device.frameKey, let resolved = DeviceFrames.lookup(key) { return resolved }
        guard let best = DeviceFrames.candidates(deviceScreenSize, tolerance: 0.1).first else { return nil }
        return ResolvedDeviceFrame(device: best, color: best.colors.first)
    }

    /// Where the video is drawn for a screen rect: the device's screen hole when a frame is
    /// on, the rect itself otherwise.
    func videoRect(inScreen screen: Rect2) -> Rect2 {
        guard let region = activeDeviceFrame?.device.videoRegion01 else { return screen }
        return Rect2(x: screen.x + region.x * screen.width, y: screen.y + region.y * screen.height, width: region.width * screen.width, height: region.height * screen.height)
    }

    /// The frame drawn around the recording (`hwD.t`): resolved and turned on.
    var activeDeviceFrame: ResolvedDeviceFrame? { isUsingDeviceFrame ? resolvedDeviceFrame : nil }

    /// The panel's list, "Perfect" (exact aspect) or "Flexible" (within 0.1), catalog order.
    func deviceFrameChoices(perfect: Bool) -> [DeviceFrame] {
        guard canHaveDeviceFrame else { return [] }
        return DeviceFrames.candidates(deviceScreenSize, tolerance: perfect ? 0 : 0.1, sorted: false)
    }

    /// `changeBorderRadius` / `changeInset`.
    var canChangeScreenBorderRadius: Bool { !(isUsingDeviceFrame || recording.isScreenContinuity || recording.isExternalDeviceMode && device.enableMockup) }
    var canChangeScreenInset: Bool { !isUsingDeviceFrame && !recording.isScreenContinuity && !recording.isExternalDeviceMode }
}
