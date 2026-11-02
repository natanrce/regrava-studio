import CoreImage
import Foundation
import RegravaCore

/// Removes 8-bit banding: each pixel takes the mean of a few random crosses of neighbours when
/// they are all within a threshold of it, then gets a full step of Bayer dither. Works on
/// sRGB-encoded values, at the texture's own pixels.
enum Deband {
    struct Settings: Equatable {
        var thresholdEightBitSteps: Double
        var radiusTexels: Double
        /// At most 4.
        var iterations: Int

        /// The wallpaper processor's defaults.
        static let wallpaper = Settings(thresholdEightBitSteps: 3, radiusTexels: 16, iterations: 4)
        /// A full 8-bit step of dither.
        static let ditherStep = 1.0 / 255

        var isOff: Bool { thresholdEightBitSteps <= 0 || radiusTexels <= 0 || iterations <= 0 }
    }

    /// The recording's settings for `improveRecordingQuality01`, before motion.
    static func recordingKnobs(quality01: Double) -> (thresholdEightBitSteps: Double, iterations: Int) {
        let q = min(1, max(0, quality01))
        guard q > 0 else { return (0, 0) }
        return (q * 4, Int(min(4, max(1, (q * 4).rounded(.up)))))
    }

    /// Full strength up to this much motion, none from `zeroStrengthMotionDevicePx`.
    static let fullStrengthMotionDevicePx = 10.0
    static let zeroStrengthMotionDevicePx = 30.0

    /// 1 − smoothstep of the motion between the two limits, in steps of 1/16.
    static func motionStrength(_ motionDevicePx: Double) -> Double {
        let t = clamp((motionDevicePx - fullStrengthMotionDevicePx) / max(zeroStrengthMotionDevicePx - fullStrengthMotionDevicePx, 0.000001), 0, 1)
        return clamp(((1 - t * t * (3 - 2 * t)) / (1.0 / 16)).rounded() * (1.0 / 16), 0, 1)
    }

    /// `slowestPixelMotionDevicePx`: per axis, the smaller move of the two edges when both go
    /// the same way (0 otherwise), combined.
    static func slowestPixelMotion(_ now: Rect2, _ before: Rect2) -> Double {
        func axis(_ a: Double, _ b: Double) -> Double { a * b <= 0 ? 0 : min(abs(a), abs(b)) }
        let x = axis(now.x - before.x, now.x + now.width - (before.x + before.width))
        let y = axis(now.y - before.y, now.y + now.height - (before.y + before.height))
        return hypot(x, y)
    }

    /// `screenDebandKnobsAt`: export and high-quality pauses only, the threshold eased out
    /// while the screen moves (its slowest pixel motion × the motion blur amount).
    static func recordingSettings(quality01: Double, motionBlurAmount: Double, screen now: Rect2, before: Rect2?, quality: RenderQuality) -> Settings {
        guard quality == .export || quality == .pausedHigh else { return Settings(thresholdEightBitSteps: 0, radiusTexels: 16, iterations: 0) }
        let knobs = recordingKnobs(quality01: quality01)
        let strength = motionStrength(slowestPixelMotion(now, before ?? now) * motionBlurAmount)
        return Settings(thresholdEightBitSteps: knobs.thresholdEightBitSteps * strength, radiusTexels: 16, iterations: knobs.iterations)
    }

    private static let kernel = RenderKernels.general("deband")

    /// `image` debanded over its own extent.
    static func apply(_ image: CIImage, settings: Settings) -> CIImage {
        guard !settings.isOff, let kernel, !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        let extent = image.extent
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve").clampedToExtent()
        let reach = settings.radiusTexels * Double(min(settings.iterations, 4)) + 2
        guard let out = kernel.apply(
            extent: extent,
            roiCallback: { _, r in r.insetBy(dx: -reach, dy: -reach).intersection(extent) },
            arguments: [
                encoded,
                CIVector(x: settings.thresholdEightBitSteps / 255, y: settings.radiusTexels, z: CGFloat(min(settings.iterations, 4)), w: Settings.ditherStep),
                CIVector(x: extent.width, y: extent.height, z: extent.minX, w: extent.minY),
            ]
        ) else { return image }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }
}
