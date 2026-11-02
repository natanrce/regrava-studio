import CoreImage
import Foundation
import RegravaCore

/// The background behind the session: a texture (image, wallpaper, gradient or colour) laid
/// out to cover a rect that follows the screen zoom, blurred by a radius in stage pixels.
///
/// Blur radii follow the texture sampler's convention: a radius `r` is a Gaussian of
/// sigma `r / 2`.
final class Backdrop: @unchecked Sendable {
    /// Gradients are drawn at most this many pixels on the long side.
    static let gradientMaxSide = 1024.0
    /// `BLUR_SIGMA_PER_RADIUS`.
    static let sigmaPerRadius = 0.5
    /// `MIN_SIGMA_PX`: below it a read is not blurred.
    static let minSigma = 0.02

    private enum Texture {
        case solid(CIColor)
        case image(CIImage)
    }

    private let texture: Texture
    /// Canvas pixels per stage pixel.
    private let scale: Double
    private let canvas: CGRect
    let styleBlurRadius: Double
    private let lock = NSLock()
    private var placed: [Key: CIImage] = [:]
    private var order: [Key] = []

    private struct Key: Hashable {
        var bounds: CGRect
        var radius: Double
    }

    init(_ config: BackgroundConfig, layout: CanvasLayout, assetsDirectory: URL?) {
        let c = layout.canvas
        canvas = CGRect(x: 0, y: 0, width: c.width, height: c.height)
        scale = layout.scale
        let stage = Size2(width: c.width / max(layout.scale, 0.000001), height: c.height / max(layout.scale, 0.000001))
        styleBlurRadius = config.blurRadius(stageWidth: stage.width)
        texture = Self.texture(config, stage: stage, assetsDirectory: assetsDirectory, styleBlurRadius: styleBlurRadius)
    }

    /// What the background draws. An image, Unsplash or system background without a
    /// file shows the plain colour.
    private static func texture(_ config: BackgroundConfig, stage: Size2, assetsDirectory: URL?, styleBlurRadius: Double) -> Texture {
        let solid = Texture.solid(FrameCompositor.ciColor(config.color))
        switch config.kind {
        case .gradient:
            return .image(gradient(config.gradient, stage: stage))
        case .color, .unsplash:
            return solid
        case .image:
            guard let name = config.imageFileName, let directory = assetsDirectory,
                  let image = CIImage(contentsOf: directory.appendingPathComponent(name)) else { return solid }
            return .image(atOrigin(image).insertingIntermediate(cache: true))
        case .wallpaper:
            guard let url = WallpaperLibrary.url(for: config.systemName), let image = CIImage(contentsOf: url) else { return solid }
            return .image(atOrigin(image).insertingIntermediate(cache: true))
        }
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// The background covering `bounds` (canvas pixels, top-left), blurred by `radius` stage
    /// pixels, on the canvas. Kept while the same placement repeats.
    func image(bounds: Rect2, radius: Double) -> CIImage {
        let rect = CGRect(x: bounds.x, y: canvas.height - bounds.y - bounds.height, width: bounds.width, height: bounds.height)
        let key = Key(bounds: rect, radius: max(0, radius))
        lock.lock()
        if let image = placed[key] {
            lock.unlock()
            return image
        }
        lock.unlock()
        let image = render(rect, radius: key.radius).insertingIntermediate(cache: true)
        lock.lock()
        placed[key] = image
        order.append(key)
        // The resting placement and the loupe's frost, plus a few in between.
        if order.count > 6 { placed[order.removeFirst()] = nil }
        lock.unlock()
        return image
    }

    /// `$getCoverFit` then `sampleBlurred`: the texture scaled to cover `rect` around its
    /// centre, clamped past its edges.
    private func render(_ rect: CGRect, radius: Double) -> CIImage {
        let sigma = radius * Self.sigmaPerRadius * scale
        switch texture {
        case .solid(let color):
            return CIImage(color: color).cropped(to: canvas)
        case .image(let image):
            let size = image.extent.size
            let k = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
            var covered = image
                .transformed(by: CGAffineTransform(scaleX: k, y: k), highQualityDownsample: k < 1)
            covered = covered.transformed(by: CGAffineTransform(
                translationX: rect.midX - covered.extent.width / 2 - covered.extent.minX,
                y: rect.midY - covered.extent.height / 2 - covered.extent.minY
            )).clampedToExtent()
            if sigma > Self.minSigma {
                covered = covered.applyingGaussianBlur(sigma: sigma)
            }
            return covered.cropped(to: canvas)
        }
    }

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
