import CoreImage
import Foundation
import RegravaCore

/// Masks drawn, through a smooth-cornered rect (smoothing 1) with a smoothstep edge:
/// - sensitive data: inside, the recording is replaced by a smooth field interpolated between
///   the average colours of the area's four quadrants;
/// - highlight: outside, the recording is darkened towards black by the highlight opacity.
///
/// Colours mix as squares of their sRGB-encoded values, and the quadrant averages are taken on
/// encoded values.
enum MaskRenderer {
    private static let applyKernel = RenderKernels.general("maskApply")
    private static let mipKernel = RenderKernels.general("mipDown")
    private static let colorsKernel = RenderKernels.general("maskCoverColors")

    /// Most reads per quadrant.
    static let maxTapsPerQuadrant = 256
    /// A mip level is used only while the area's shorter side spans this many of its texels.
    static let minTexelsPerSide = 8.0

    /// `image` is the recording with its origin at (0, 0) and the recording's pixel size;
    /// `antialias` is the edge half-width in recording pixels.
    static func apply(_ mask: MaskFrame, to image: CIImage, antialias: Double = SmoothShapes.antialias) -> CIImage {
        guard mask.isVisible, mask.bounds01.width > 0, mask.bounds01.height > 0, let kernel = applyKernel else { return image }
        let extent = image.extent
        let size = extent.size
        let bounds = Rect2(x: mask.bounds01.x * size.width, y: mask.bounds01.y * size.height, width: mask.bounds01.width * size.width, height: mask.bounds01.height * size.height)
        let corner = SmoothShapes.Corner(size: CGSize(width: bounds.width, height: bounds.height), radius: mask.borderRadius01 * size.width, smoothing: 1)
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let colors = (mask.coversArea ? coverColors(encoded, bounds: bounds) : nil) ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let out = kernel.apply(
            extent: extent,
            roiCallback: { index, rect in index == 0 ? rect : CGRect(x: 0, y: 0, width: 2, height: 2) },
            arguments: [
                encoded,
                colors.clampedToExtent(),
                CIVector(x: bounds.x, y: bounds.y, z: bounds.width, w: bounds.height),
                CIVector(x: corner.extent, y: antialias, z: mask.effectiveOpacity, w: mask.highlightOpacity),
                CIVector(x: size.width, y: size.height, z: mask.coversArea ? 1 : 0, w: 0),
            ] + corner.lut
        ) else { return image }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// The reads that average each quadrant: the mask area inside the recording, inset by the
    /// mip level's footprint, read at the coarsest level (from 0, at most log2 of the shorter
    /// side over 8) that needs no more than 256 reads per quadrant.
    struct Lattice: Equatable {
        /// Top-left recording pixels.
        var rect: Rect2
        var tapsX: Int
        var tapsY: Int
        var level: Int
    }

    static func lattice(bounds: Rect2, contentSize: CGSize, mipLevelCount: Int) -> Lattice? {
        let x0 = max(0, bounds.x), y0 = max(0, bounds.y)
        let x1 = min(contentSize.width, bounds.x + bounds.width), y1 = min(contentSize.height, bounds.y + bounds.height)
        guard x1 > x0, y1 > y0 else { return nil }
        let area = Rect2(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let maxLevel = min(max(0, mipLevelCount - 1), max(0, Int(floor(log2(min(area.width, area.height) / minTexelsPerSide)))))
        var level = 0
        while true {
            let texel = pow(2, Double(level))
            let pad = texel + mipFootprint(level: level)
            let dx = min(pad, area.width / 2), dy = min(pad, area.height / 2)
            let inset = Rect2(x: area.x + dx, y: area.y + dy, width: area.width - 2 * dx, height: area.height - 2 * dy)
            let x = max(1, Int((inset.width / 2 / texel).rounded(.up))), y = max(1, Int((inset.height / 2 / texel).rounded(.up)))
            if !(x * y > maxTapsPerQuadrant && level < maxLevel) {
                let taps = limitTaps(x, y)
                return Lattice(rect: inset, tapsX: taps.x, tapsY: taps.y, level: level)
            }
            level += 1
        }
    }

    /// At most 256 reads, cutting the longer side first.
    static func limitTaps(_ x: Int, _ y: Int) -> (x: Int, y: Int) {
        if x * y <= maxTapsPerQuadrant { return (x, y) }
        if x >= y { return (max(1, maxTapsPerQuadrant / y), min(y, maxTapsPerQuadrant)) }
        return (min(x, maxTapsPerQuadrant), max(1, maxTapsPerQuadrant / x))
    }

    /// How far a texel of mip `level` reaches, in level-0 texels: half a texel, plus every
    /// level's widest tap (2-tap box at level 1, [1, 3, 3, 1] after) times its texel size.
    static func mipFootprint(level: Int) -> Double {
        var reach = 0.5
        guard level >= 1 else { return reach }
        for l in 1...level {
            reach += (l <= 1 ? 0.5 : 1.5) * pow(2, Double(l - 1))
        }
        return reach
    }

    /// The 2×2 quadrant averages (row 1 = the top quadrants) of an encoded recording.
    private static func coverColors(_ encoded: CIImage, bounds: Rect2) -> CIImage? {
        guard let mipKernel, let colorsKernel else { return nil }
        let size = encoded.extent.size
        let levels = Int(floor(log2(max(size.width, size.height, 1)))) + 1
        guard let lattice = lattice(bounds: bounds, contentSize: size, mipLevelCount: levels) else { return nil }
        var mip = encoded
        var mipSize = size
        if lattice.level >= 1 {
            for level in 1...lattice.level {
                let next = CGSize(width: max(1, floor(mipSize.width / 2)), height: max(1, floor(mipSize.height / 2)))
                let previous = mipSize
                let binomial = level > 1
                guard let down = mipKernel.apply(
                    extent: CGRect(origin: .zero, size: next),
                    roiCallback: { _, r in
                        let reach: CGFloat = binomial ? 2 : 1
                        return CGRect(x: r.minX * 2 - reach, y: r.minY * 2 - reach, width: r.width * 2 + 2 * reach, height: r.height * 2 + 2 * reach)
                            .intersection(CGRect(origin: .zero, size: previous))
                    },
                    arguments: [mip, CIVector(x: previous.width, y: previous.height, z: next.height, w: binomial ? 1 : 0)]
                ) else { return nil }
                mip = down
                mipSize = next
            }
        }
        let texel = pow(2, Double(lattice.level))
        let read = CGRect(x: lattice.rect.x / texel - 2, y: mipSize.height - (lattice.rect.y + lattice.rect.height) / texel - 2,
                          width: lattice.rect.width / texel + 4, height: lattice.rect.height / texel + 4)
        return colorsKernel.apply(
            extent: CGRect(x: 0, y: 0, width: 2, height: 2),
            roiCallback: { _, _ in read },
            arguments: [
                mip.clampedToExtent(),
                CIVector(x: lattice.rect.x, y: lattice.rect.y, z: lattice.rect.width, w: lattice.rect.height),
                CIVector(x: CGFloat(lattice.tapsX), y: CGFloat(lattice.tapsY), z: texel, w: mipSize.height),
            ]
        )
    }
}
