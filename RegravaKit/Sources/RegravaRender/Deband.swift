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
