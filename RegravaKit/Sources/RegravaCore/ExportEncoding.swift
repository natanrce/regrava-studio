import Foundation

/// Which encoder writes an MP4 video stream.
public enum VideoEncoderKind: String, Codable, Sendable {
    /// The linked software encoder (H.264 only).
    case videoEncoder = "video-encoder"
    /// The system's hardware encoder (VideoToolbox).
    case hardware
}

/// How a video stream's `rate` is read.
public enum VideoRateMode: String, Codable, Sendable {
    /// `rate` is a constant rate factor.
    case crf
    /// `rate` is bits per second.
    case bitrate
}

/// Rate control of one MP4 video stream.
public struct VideoRateControl: Equatable, Sendable {
    public var codec: ExportCodec
    public var encoder: VideoEncoderKind
    public var rateMode: VideoRateMode
    public var rate: Double
}

/// GIF encoder modes: `balanced` is the default compromise, `high` gives larger files with fewer
/// artifacts.
public enum GifQualityMode: String, Codable, Sendable {
    case balanced, high
}

public extension ExportQuality {
    /// The GIF encoder mode for this quality.
    var gifMode: GifQualityMode { self == .studio ? .high : .balanced }
}

/// Encoder parameters for each export quality.
public enum ExportEncoding {
    /// Bits per pixel per frame of a bitrate-driven (hardware) stream.
    public static func hardwareBitsPerPixel(_ quality: ExportQuality) -> Double {
        switch quality {
        case .webLow: return 0.0075
        case .webHigh: return 0.0175
        case .socialMedia: return 0.05
        case .studio: return 0.3
        }
    }

    /// Constant rate factor of a quantizer-driven H.264 stream.
    public static func quantizer(_ quality: ExportQuality) -> Int {
        switch quality {
        case .webLow: return 42
        case .webHigh: return 30
        case .socialMedia: return 24
        case .studio: return 14
        }
    }

    /// Bits per second for a stream that has to run on a bitrate:
    /// floor(width × height × fps × bits per pixel).
    public static func bitsPerSecond(quality: ExportQuality, width: Double, height: Double, fps: Int) -> Double {
        (width * height * Double(fps) * hardwareBitsPerPixel(quality)).rounded(.down)
    }

    /// The codecs written for a codec choice: "Both" writes H.264 and HEVC to a file only.
    public static func codecs(_ codec: ExportCodec, target: ExportTarget?) -> [ExportCodec] {
        switch codec {
        case .h265: return [.h265]
        case .both where target == .file: return [.h264, .h265]
        default: return [.h264]
        }
    }

    /// H.264 runs on the linked encoder at a constant rate factor; HEVC runs on the hardware
    /// encoder at a bitrate.
    public static func rateControl(codec: ExportCodec, quality: ExportQuality, width: Double, height: Double, fps: Int) -> VideoRateControl {
        let fallback = bitsPerSecond(quality: quality, width: width, height: height, fps: fps)
        if codec == .h264 {
            return VideoRateControl(codec: codec, encoder: .videoEncoder, rateMode: .crf, rate: Double(quantizer(quality)))
        }
        return VideoRateControl(codec: codec, encoder: .hardware, rateMode: .bitrate, rate: fallback)
    }

    /// The bitrate a hardware encoder runs a stream at: a quantizer stream converts to its
    /// fallback bitrate first.
    public static func hardwareBitsPerSecond(codec: ExportCodec, quality: ExportQuality, width: Double, height: Double, fps: Int) -> Double {
        let control = rateControl(codec: codec, quality: quality, width: width, height: height, fps: fps)
        return control.rateMode == .bitrate ? control.rate : bitsPerSecond(quality: quality, width: width, height: height, fps: fps)
    }

    /// Whole frames per second the hardware writer runs at (at least 1).
    public static func writerFrameRate(_ fps: Int) -> Int { fps < 2 ? 1 : fps }

    /// Longest distance between keyframes: two seconds of frames.
    public static func maxKeyFrameInterval(fps: Int) -> Int { writerFrameRate(fps) * 2 }

    /// AAC bitrate of an MP4's sound.
    public static let aacBitsPerSecond = 192_000
    /// Sample rate of every export's sound.
    public static let audioSampleRate = 48_000.0
    /// Bit depth of a ProRes movie's uncompressed sound.
    public static let pcmBitDepth = 24
}
