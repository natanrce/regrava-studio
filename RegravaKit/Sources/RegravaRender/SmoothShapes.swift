import CoreImage
import Foundation
import RegravaCore

/// The part masks and shadows: Figma smooth corners at smoothing 1 with a 3 px edge, and
/// Classic or Directional shadows of the same shape. Rects are in Core Image coordinates (y
/// up), sizes in canvas pixels.
enum SmoothShapes {
    private static let coverageKernel = RenderKernels.general("smoothRectCoverage")
    private static let shadowKernel = RenderKernels.general("partShadow")

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
}
