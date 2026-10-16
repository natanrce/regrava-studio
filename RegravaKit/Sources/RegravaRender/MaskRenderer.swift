import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RegravaCore

/// Masks drawn:
/// - sensitive data: inside the rounded rectangle the recording is replaced by a smooth field
///   interpolated between the average colours of the area's four quadrants;
/// - highlight: outside it the recording is darkened towards black by the highlight opacity.
enum MaskRenderer {
    /// Bilinear field between the four quadrant colours, one per corner of `rect`
    /// (the 2×2 texture sampled at uv × 0.5 + 0.25).
    nonisolated(unsafe) private static let coverKernel = CIKernel(source: """
    kernel vec4 maskCover(sampler colors, vec4 rect) {
        vec2 p = clamp((destCoord() - rect.xy) / rect.zw, 0.0, 1.0);
        return sample(colors, samplerTransform(colors, p + vec2(0.5)));
    }
    """)

    /// `image` is the recording with its origin at (0, 0) and the recording's pixel size.
    static func apply(_ mask: MaskFrame, to image: CIImage) -> CIImage {
        guard mask.isVisible, mask.bounds01.width > 0, mask.bounds01.height > 0 else { return image }
        let size = image.extent.size
        // Top-left fractions to Core Image's bottom-left pixels.
        let rect = CGRect(
            x: mask.bounds01.x * size.width,
            y: (1 - mask.bounds01.y - mask.bounds01.height) * size.height,
            width: mask.bounds01.width * size.width,
            height: mask.bounds01.height * size.height
        )
        let radius = min(mask.borderRadius01 * size.width, min(rect.width, rect.height) / 2)
        let inside = roundedRect(rect, radius: radius)
        let opacity = mask.effectiveOpacity

        if mask.coversArea {
            guard let cover = cover(of: image, in: rect) else { return image }
            return blend(cover, over: image, mask: inside, alpha: opacity)
        }
        // Highlight: darken outside by highlightOpacity × opacity.
        let outside = CIImage(color: .white).cropped(to: image.extent)
            .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inside])
        let black = CIImage(color: .black).cropped(to: image.extent)
        return blend(black, over: image, mask: outside, alpha: mask.highlightOpacity * opacity)
    }

    private static func cover(of image: CIImage, in rect: CGRect) -> CIImage? {
        guard let kernel = coverKernel else { return nil }
        let halfW = rect.width / 2, halfH = rect.height / 2
        // Quadrant averages placed as a 2×2 image: x 0 = left, y 0 = bottom.
        var colors = CIImage.empty()
        for (i, j) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let quadrant = CGRect(x: rect.minX + CGFloat(i) * halfW, y: rect.minY + CGFloat(j) * halfH, width: halfW, height: halfH)
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: quadrant)])
            let pixel = average
                .transformed(by: CGAffineTransform(translationX: CGFloat(i) - average.extent.minX, y: CGFloat(j) - average.extent.minY))
                .cropped(to: CGRect(x: i, y: j, width: 1, height: 1))
            colors = pixel.composited(over: colors)
        }
        colors = colors.clampedToExtent()
        return kernel.apply(
            extent: rect,
            roiCallback: { _, _ in CGRect(x: -1, y: -1, width: 4, height: 4) },
            arguments: [colors, CIVector(cgRect: rect)]
        )
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(max(radius, 0))
        generator.color = .white
        return generator.outputImage ?? CIImage.empty()
    }

    /// `top` over `base` through `mask` scaled by `alpha`.
    private static func blend(_ top: CIImage, over base: CIImage, mask: CIImage, alpha: Double) -> CIImage {
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(alpha), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(alpha), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(alpha), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let filter = CIFilter.blendWithMask()
        filter.inputImage = top
        filter.backgroundImage = base
        filter.maskImage = scaledMask
        return (filter.outputImage ?? base).cropped(to: base.extent)
    }
}
