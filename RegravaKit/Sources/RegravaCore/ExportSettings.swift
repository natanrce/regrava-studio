import Foundation

/// Export options, mirroring the export model.
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case mp4, prores, gif

    public var label: String {
        switch self {
        case .mp4: return "MP4"
        case .prores: return "ProRes"
        case .gif: return "GIF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .prores: return "mov"
        case .gif: return "gif"
        }
    }

    public var fpsOptions: [Int] {
        self == .gif ? [50, 30, 25, 20, 15, 10] : [60, 50, 30, 25, 24, 20, 10]
    }

    public var qualityOptions: [ExportQuality] {
        switch self {
        case .mp4: return [.studio, .socialMedia, .webHigh, .webLow]
        case .prores: return [.studio]
        case .gif: return [.studio, .socialMedia]
        }
    }

    /// Output heights.
    public var resolutionOptions: [Int] {
        self == .gif ? [480, 720, 1080] : [720, 1080, 2160]
    }
}

public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case studio
    case socialMedia = "social-media"
    case webHigh = "web-high"
    case webLow = "web-low"

    public var label: String {
        switch self {
        case .studio: return "Studio"
        case .socialMedia: return "Social Media"
        case .webHigh: return "Web"
        case .webLow: return "Web (Low)"
        }
    }

    public var isWeb: Bool { self == .webHigh || self == .webLow }
}

public enum ExportCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case h265
    case both

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "HEVC"
        case .both: return "Both"
        }
    }
}

public enum ProResProfile: String, Codable, CaseIterable, Sendable {
    case lt = "422-lt"
    case standard = "422"
    case hq = "422-hq"
    case p4444 = "4444"

    public var label: String {
        switch self {
        case .lt: return "422 LT"
        case .standard: return "422"
        case .hq: return "422 HQ"
        case .p4444: return "4444"
        }
    }
}

public enum ExportTarget: String, Codable, CaseIterable, Sendable {
    case file, clipboard, link
}

public enum LinkVisibility: String, Codable, Sendable {
    case `public`, `private`
}

public struct ExportSettings: Codable, Hashable, Sendable {
    public var format: ExportFormat
    public var fps: Int
    public var quality: ExportQuality
    public var height: Int
    public var codec: ExportCodec
    public var proresProfile: ProResProfile
    public var gifDisableLoop: Bool

    public init(
        format: ExportFormat,
        fps: Int,
        quality: ExportQuality,
        height: Int,
        codec: ExportCodec = .h264,
        proresProfile: ProResProfile = .hq,
        gifDisableLoop: Bool = false
    ) {
        self.format = format
        self.fps = fps
        self.quality = quality
        self.height = height
        self.codec = codec
        self.proresProfile = proresProfile
        self.gifDisableLoop = gifDisableLoop
    }

    /// Per-format defaults.
    public static func defaults(for format: ExportFormat) -> ExportSettings {
        switch format {
        case .mp4: return ExportSettings(format: .mp4, fps: 60, quality: .socialMedia, height: 720, codec: .h264)
        case .prores: return ExportSettings(format: .prores, fps: 60, quality: .studio, height: 1080, proresProfile: .hq)
        case .gif: return ExportSettings(format: .gif, fps: 15, quality: .socialMedia, height: 480)
        }
    }

    /// Resolutions currently allowed (web qualities cap at 1080p).
    public var allowedResolutions: [Int] {
        let all = format.resolutionOptions
        return quality.isWeb ? all.filter { $0 <= 1080 } : all
    }

    public func codecOptions(target: ExportTarget?) -> [ExportCodec] {
        target == .file ? [.h264, .h265, .both] : [.h264, .h265]
    }

    /// Snaps every field to a value valid for the format (nearest lower option, else highest).
    public func normalized(target: ExportTarget? = nil) -> ExportSettings {
        var s = self
        func snap(_ value: Int, _ options: [Int]) -> Int {
            options.filter { $0 <= value }.max() ?? options.max() ?? value
        }
        s.fps = snap(fps, format.fpsOptions)
        if !format.qualityOptions.contains(s.quality) { s.quality = format.qualityOptions[0] }
        s.height = snap(height, s.allowedResolutions)
        if !codecOptions(target: target).contains(s.codec) { s.codec = .h264 }
        return s
    }

    /// "MP4 • 720p • 60fps • Social Media" style summary.
    public func summary(visibility: LinkVisibility? = nil) -> String {
        var parts = [format.label]
        switch format {
        case .mp4:
            if codec == .h265 { parts.append("HEVC") }
            if codec == .both { parts.append("H.264 + HEVC") }
        case .prores:
            parts.append(proresProfile.label)
        case .gif:
            break
        }
        parts.append("\(height)p")
        parts.append("\(fps)fps")
        if format != .prores { parts.append(quality.label) }
        if let visibility { parts.append(visibility == .private ? "Private" : "Public") }
        return parts.joined(separator: " • ")
    }

    /// Largest output video: anything bigger is scaled down to fit inside it.
    public static let maxOutputSize = Size2(width: 3840, height: 2160)

    /// Output pixel size for a stage aspect ratio at this height: even numbers, at least 2,
    /// fitted inside `maxOutputSize`.
    public func outputSize(aspectRatio: Double) -> Size2 {
        Self.outputSize(aspectRatio: aspectRatio, height: Double(height))
    }

    public static func outputSize(aspectRatio: Double, height desiredHeight: Double) -> Size2 {
        var h = evenPixels(desiredHeight)
        var w = evenPixels(h * aspectRatio)
        if w > maxOutputSize.width || h > maxOutputSize.height {
            let scale = min(maxOutputSize.width / w, maxOutputSize.height / h)
            w = evenPixels(w * scale)
            h = evenPixels(h * scale)
        }
        return Size2(width: w, height: h)
    }

    /// A pixel length for the encoder: the integer it is within 1e-6 of, else rounded down;
    /// an odd value goes down to the even one below it; never under 2.
    public static func evenPixels(_ value: Double) -> Double {
        let nearest = value.rounded()
        let whole = abs(value - nearest) < 0.000001 ? nearest : value.rounded(.down)
        let even = whole.truncatingRemainder(dividingBy: 2) == 0 ? whole : whole - 1
        return max(even, 2)
    }

    public static func resolutionLabel(_ height: Int) -> String {
        height == 2160 ? "4K" : "\(height)p"
    }
}

/// Remembers the last settings per format plus the preferred format/target ("export-settings"
/// and "widget-export-settings").
public struct ExportSettingsStore: Codable, Hashable, Sendable {
    public var perFormat: [ExportFormat: ExportSettings]
    public var preferredFormat: ExportFormat
    public var preferredTarget: ExportTarget
    public var linkVisibility: LinkVisibility

    public init() {
        perFormat = Dictionary(uniqueKeysWithValues: ExportFormat.allCases.map { ($0, ExportSettings.defaults(for: $0)) })
        preferredFormat = .mp4
        preferredTarget = .file
        linkVisibility = .public
    }

    public var current: ExportSettings {
        get { perFormat[preferredFormat] ?? .defaults(for: preferredFormat) }
        set {
            preferredFormat = newValue.format
            perFormat[newValue.format] = newValue.normalized()
        }
    }

    public mutating func select(format: ExportFormat) {
        preferredFormat = format
    }
}
