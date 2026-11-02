import CoreImage
import Foundation
import RegravaCore

/// The part masks and shadows: Figma smooth corners at smoothing 1 with a 3 px edge, and
/// Classic or Directional shadows of the same shape. Rects are in Core Image coordinates (y
/// up), sizes in canvas pixels.
enum SmoothShapes {
    private static let coverageKernel = RenderKernels.general("smoothRectCoverage")
    private static let shadowKernel = RenderKernels.general("partShadow")
    private static let contentShadowKernel = RenderKernels.general("contentShadow")

    /// `ANTIALIAS_SCREEN_PIXELS`: half the edge ramp.
    static let antialias = 1.5

    struct Corner {
        /// Where the curve starts (2r at smoothing 1).
        var extent: Double
        var lut: [CIVector]
        /// The circular radius `min(r, minSide/2)` of the far shadow caster.
        var circular: Double

        init(size: CGSize, radius: Double, smoothing: Double = 1) {
            let r = max(radius, 0)
            extent = SmoothCorners.extent(width: size.width, height: size.height, radius: r, smoothing: smoothing)
            circular = min(r, min(size.width, size.height) / 2)
            let table = SmoothCorners.lut(width: size.width, height: size.height, radius: r, smoothing: smoothing)
            lut = stride(from: 0, to: 16, by: 4).map { CIVector(x: table[$0], y: table[$0 + 1], z: table[$0 + 2], w: table[$0 + 3]) }
        }
    }

    /// White coverage of `rect` with smooth corners of `radius`; `edge` grows the shape outward
    /// (the inset band's threshold).
    static func coverage(_ rect: CGRect, radius: Double, smoothing: Double = 1, half: CGSize? = nil, center: CGPoint? = nil, edge: Double = 0) -> CIImage {
        let c = center ?? CGPoint(x: rect.midX, y: rect.midY)
        let h = half ?? CGSize(width: rect.width / 2, height: rect.height / 2)
        let corner = Corner(size: CGSize(width: rect.width, height: rect.height), radius: radius, smoothing: smoothing)
        let pad = edge + antialias + 1
        let extent = CGRect(x: c.x - h.width - pad, y: c.y - h.height - pad, width: 2 * (h.width + pad), height: 2 * (h.height + pad))
        guard let kernel = coverageKernel, rect.width > 0, rect.height > 0 else { return CIImage.empty() }
        return kernel.apply(
            extent: extent,
            roiCallback: { _, r in r },
            arguments: [
                CIVector(x: c.x, y: c.y, z: h.width, w: h.height),
                CIVector(x: corner.extent, y: antialias, z: edge, w: 0),
            ] + corner.lut
        ) ?? CIImage.empty()
    }

    /// `image` clipped to `rect` with smooth corners.
    static func clip(_ image: CIImage, to rect: CGRect, radius: Double, smoothing: Double = 1) -> CIImage {
        image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: coverage(rect, radius: radius, smoothing: smoothing)])
    }

    /// The inset: a band `size` thick outside `rect`, shifted by `(1 − 2·origin01)·size` (y
    /// down), drawn behind the content.
    static func insetBand(_ rect: CGRect, radius: Double, size: Double, origin01: Vec2, color: CIColor) -> CIImage {
        guard size > 0 else { return CIImage.empty() }
        let h = size / 2
        let o = CGPoint(x: (1 - 2 * origin01.x) * size, y: -(1 - 2 * origin01.y) * size)
        let band = coverage(rect, radius: radius, half: CGSize(width: rect.width / 2 + h, height: rect.height / 2 + h),
                            center: CGPoint(x: rect.midX + o.x, y: rect.midY + o.y), edge: h)
        return CIImage(color: color).cropped(to: band.extent).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: band])
    }

    struct Shadow {
        var alpha: Double
        /// Classic ramp width (pixels).
        var blur: Double
        /// Classic offset, Core Image direction (y up).
        var offset: CGVector
        /// Directional: light position on the canvas (Core Image), light radius and reach.
        var directional: (light: CGPoint, radius: Double, falloff: Double)?
        /// Pixels per stage unit, for the ray-march steps.
        var unit: Double
        /// Corner smoothing of the caster (a device body's `frameBorderRoundness`).
        var smoothing: Double = 1
        /// How far the caster shrinks inside the shape (a device body's `frameBodyInset`).
        var inset: Double = 0
    }

    /// The black shadow of a smooth-cornered `rect`, to draw under it.
    static func shadow(_ rect: CGRect, radius: Double, _ s: Shadow) -> CIImage {
        guard let kernel = shadowKernel, s.alpha > 0, rect.width > 0, rect.height > 0 else { return CIImage.empty() }
        // The caster shrinks by the inset, at most a quarter of the shorter side.
        let inset = clamp(s.inset, 0, min(rect.width, rect.height) * 0.25)
        let rect = rect.insetBy(dx: inset, dy: inset)
        let corner = Corner(size: rect.size, radius: radius, smoothing: s.smoothing)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // `fieldExtents`: half + reach + 16.
        let reach = s.directional.map { $0.falloff } ?? (max(abs(s.offset.dx), abs(s.offset.dy)) + s.blur)
        let extent = rect.insetBy(dx: -(reach + 16 * s.unit), dy: -(reach + 16 * s.unit))
        let light = s.directional.map { CIVector(x: $0.light.x - center.x, y: $0.light.y - center.y, z: $0.radius, w: $0.falloff) } ?? CIVector(x: 0, y: 0, z: 1, w: 1)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, r in r },
            arguments: [
                CIVector(x: center.x, y: center.y, z: rect.width / 2, w: rect.height / 2),
                CIVector(x: corner.extent, y: corner.circular, z: antialias, w: s.directional == nil ? 0 : 1),
                CIVector(x: s.blur, y: s.offset.dx, z: s.offset.dy, w: s.alpha),
                light,
                Float(s.unit),
            ] + corner.lut
        ) ?? CIImage.empty()
    }

    /// The black shadow `content`'s own alpha casts (a cutout camera's silhouette), to draw
    /// under it; `rect` and `radius` are the shape that clips the content. Classic: the alpha
    /// blurred by max(blur, 1.5 px) at the offset, clipped by the shape within that radius and
    /// eased by smoothstep(0, 0.75). Directional: six reads marching toward the light, each
    /// blurred by the light's spread at that distance (at least the gap since the previous
    /// read × 1.5), the strongest one weighted by (1 − along²)². Blurs read 8 levels
    /// spaced evenly in log radius; a radius r is a Gaussian of sigma r / 2.
    static func contentShadow(_ content: CIImage, caster rect: CGRect, radius: Double, _ s: Shadow) -> CIImage {
        guard let kernel = contentShadowKernel, s.alpha > 0, rect.width > 0, rect.height > 0, !content.extent.isEmpty else { return CIImage.empty() }
        let corner = Corner(size: rect.size, radius: radius, smoothing: s.smoothing)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reach: Double
        let smallest: Double, largest: Double
        if let d = s.directional {
            let falloff = max(d.falloff, 1)
            reach = falloff
            // The light is never closer than the nearest point of the reachable area.
            let area = rect.insetBy(dx: -falloff, dy: -falloff)
            let nearest = CGPoint(x: clamp(d.light.x, area.minX, area.maxX), y: clamp(d.light.y, area.minY, area.maxY))
            let distance = max(hypot(d.light.x - nearest.x, d.light.y - nearest.y), 1)
            smallest = antialias
            largest = max(falloff * 0.85 * 0.85 * d.radius / distance, falloff * (0.85 * 0.85 - 0.7 * 0.7) * 1.5, falloff * 0.01 * 1.5, antialias)
        } else {
            let r = max(s.blur, antialias)
            reach = max(abs(s.offset.dx), abs(s.offset.dy)) + r
            smallest = r
            largest = r
        }
        let step = largest > smallest ? log2(largest / smallest) / 7 : 0
        let extent = rect.insetBy(dx: -(reach + 2), dy: -(reach + 2)).integral
        let alpha = content.clampedToExtent()
        let levels = (0..<8).map { k -> CIImage in
            let sigma = smallest * pow(2, Double(k) * step) * 0.5
            let image = sigma > 0.02 ? alpha.applyingGaussianBlur(sigma: sigma) : alpha
            return image.cropped(to: extent.insetBy(dx: -(reach + 2), dy: -(reach + 2)))
        }
        let light = s.directional.map { CIVector(x: $0.light.x - center.x, y: $0.light.y - center.y, z: $0.radius, w: $0.falloff) } ?? CIVector(x: 0, y: 0, z: 1, w: 1)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, r in r.insetBy(dx: -(reach + 2), dy: -(reach + 2)) },
            arguments: levels + [
                CIVector(x: center.x, y: center.y, z: rect.width / 2, w: rect.height / 2),
                CIVector(x: corner.extent, y: corner.circular, z: antialias, w: s.directional == nil ? 0 : 1),
                CIVector(x: s.blur, y: s.offset.dx, z: s.offset.dy, w: s.alpha),
                light,
                CIVector(x: smallest, y: step, z: 0, w: 0),
            ] + corner.lut
        ) ?? CIImage.empty()
    }
}
