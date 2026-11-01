import CoreImage
import Foundation
import RegravaCore

/// The background behind the session.
final class Backdrop: @unchecked Sendable {
    /// Gradients are drawn at most this many pixels on the long side.
    static let gradientMaxSide = 1024.0

    // MARK: Gradient

    /// The gradient drawn at the stage's aspect ratio, at most 1024 px on the long side.
    static func gradient(_ gradient: BackgroundGradient, stage: Size2) -> CIImage {
        let k = min(1, gradientMaxSide / max(stage.width, stage.height, 1))
        let width = max(1, (stage.width * k).rounded()), height = max(1, (stage.height * k).rounded())
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let uniforms = GradientUniforms(gradient)
        guard let kernel = gradientKernel,
              let encoded = kernel.apply(extent: extent, roiCallback: { _, r in r }, arguments: [
                  CIVector(x: gradient.start.x, y: gradient.start.y, z: gradient.end.x, w: gradient.end.y),
                  CIVector(x: width, y: height, z: CGFloat(uniforms.count), w: 0),
                  CIVector(values: uniforms.offsets.prefix(4).map { CGFloat($0) }, count: 4),
                  CIVector(values: uniforms.offsets.suffix(4).map { CGFloat($0) }, count: 4),
              ] + uniforms.colors.map { CIVector(x: $0.x, y: $0.y, z: $0.z, w: $0.w) })
        else { return CIImage(color: FrameCompositor.ciColor(gradient.stops.first?.color ?? RGBA(0, 0, 0))).cropped(to: extent) }
        return encoded.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent).insertingIntermediate(cache: true)
    }

    private static let gradientKernel = RenderKernels.general("oklchGradient")

    /// Stops clamped to 0…1, sorted, at most 8, as OKLCH with each hue moved to
    /// the nearest turn of the previous one (achromatic stops keep the running hue); unused
    /// slots repeat the last stop at offset 1.
    struct GradientUniforms {
        var count: Int
        var offsets: [Double]
        /// (L, C, h, alpha).
        var colors: [SIMD4<Double>]

        init(_ gradient: BackgroundGradient) {
            let stops = gradient.stops
                .map { (at: min(1, max(0, $0.at)), color: $0.color) }
                .enumerated()
                .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
                .map(\.element)
                .prefix(8)
            let fallback = [(at: 0.0, color: RGBA(0, 0, 0))]
            let list = stops.isEmpty ? fallback : Array(stops)
            let lch = list.map { Oklch(srgb: $0.color) }
            var hue = lch.first { $0.c >= 0.00001 }?.h ?? 0
            let hues = lch.map { color -> Double in
                if color.c >= 0.00001 { hue += Self.wrap(color.h - hue) }
                return hue
            }
            count = list.count
            offsets = (0..<8).map { $0 >= list.count ? 1 : list[$0].at }
            colors = (0..<8).map { i in
                let j = min(i, list.count - 1)
                return SIMD4(lch[j].l, lch[j].c, hues[j], list[j].color.a)
            }
        }

        /// A hue difference moved into (−π, π].
        static func wrap(_ d: Double) -> Double {
            d - 2 * .pi * ((d - .pi) / (2 * .pi)).rounded(.up)
        }
    }

    /// `$oklchFromSrgb`: lightness, chroma and hue (radians, 0…2π; 0 when achromatic).
    struct Oklch {
        var l: Double
        var c: Double
        var h: Double

        init(srgb color: RGBA) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(color.r), g = linear(color.g), b = linear(color.b)
            let lm = cbrt(max(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0))
            let mm = cbrt(max(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0))
            let sm = cbrt(max(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 0))
            l = 0.2104542553 * lm + 0.793617785 * mm - 0.0040720468 * sm
            let a = 1.9779984951 * lm - 2.428592205 * mm + 0.4505937099 * sm
            let bb = 0.0259040371 * lm + 0.7827717662 * mm - 0.808675766 * sm
            c = hypot(a, bb)
            var hue = 0.0
            if c >= 0.00001 {
                hue = atan2(bb, a)
                if hue < 0 { hue += 2 * .pi }
            }
            h = hue
        }
    }
}
