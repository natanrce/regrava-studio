import CoreImage
import Foundation

/// Composites layers so that no Core Image pass can read past what a layer drew.
///
/// Core Image joins a graph into as few GPU programs as it can. An input it cannot join (a
/// kernel's output, or a part split off once a program needs more than the 15 textures the
/// GPU binds) is drawn into a texture with a one-pixel ring around its extent, and the program
/// reading it clamps every read past the texture to that ring. Core Image takes the ring as
/// clear, but a layer that draws past its extent (an antialiased edge, a trail kernel) leaves
/// colour there, and the clamped reads smear it over everything around: vertical streaks
/// along the top of the background, a band down its left side.
///
/// So every layer is cleared outside its extent where it is read.
enum RenderPass {
    /// How far past its extent a layer may draw: antialiased edges spill about a pixel.
    static let fringe = 2.0

    /// `image` cleared past its extent and `fringe` in the program that reads it. A plain crop
    /// to the extent is dropped by Core Image as a no-op.
    static func clipped(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        // Core Image drops a mask wider than the image it masks, so the image is first grown
        // to the mask with clear.
        let kept = extent.insetBy(dx: -fringe, dy: -fringe).integral
        return image.composited(over: CIImage(color: .clear).cropped(to: kept))
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: kept)])
    }

    /// `layers` drawn over `base`, bottom first, each cleared outside its extent.
    static func stack(_ layers: [CIImage], over base: CIImage) -> CIImage {
        layers.filter { !$0.extent.isEmpty }.map(clipped).reduce(base) { $1.composited(over: $0) }
    }
}
