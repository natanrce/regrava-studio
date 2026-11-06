import CoreImage
import Foundation

/// Splits a frame into Core Image passes that cannot read past what an input drew.
///
/// Core Image joins a graph into as few GPU programs as it can. An input it cannot join (a
/// kernel's output, or a part split off once a program needs more than the 15 textures the
/// GPU binds) is drawn into a texture with a one-pixel ring around its extent, and the program
/// reading it clamps every read past the texture to that ring. Core Image takes the ring as
/// clear, but a layer that draws past its extent (an antialiased edge, a trail kernel) leaves
/// colour there, and the clamped reads smear it over everything around: vertical streaks
/// along the top of the background, a band down its left side.
///
/// So every layer is cleared outside its extent where it is read, and stages that gather many
/// layers end their pass well before the texture limit.
enum RenderPass {
    /// Textures one program of the frame may read; 3 below the limit, for the reads Core
    /// Image adds itself.
    static let maxTextures = 12

    /// Textures `stack` counts for each layer.
    static let texturesPerLayer = 2

    /// Textures the screen, cursor and camera over the background read, at most, in the pass
    /// that draws the frame.
    static let sessionTextures = 7

    /// `image` drawn in a pass of its own, read as one texture by the passes after it. The
    /// pass draws `rasterScale` times larger and is scaled back, for an image drawn at that
    /// scale afterwards: its pixels stay the output's.
    static func ended(_ image: CIImage, rasterScale: CGSize = CGSize(width: 1, height: 1)) -> CIImage {
        guard !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        let scale = CGAffineTransform(scaleX: rasterScale.width, y: rasterScale.height)
        guard rasterScale != CGSize(width: 1, height: 1) else { return clipped(image).insertingIntermediate(cache: false) }
        return clipped(image.transformed(by: scale)).insertingIntermediate(cache: false).transformed(by: scale.inverted())
    }

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

    /// `layers` drawn over `base`, bottom first, each cleared outside its extent. Past
    /// `maxTextures`, runs of layers are drawn over clear inside their own bounds in passes
    /// of their own and those runs composited instead, as many times as it takes, so the pass
    /// over `base` reads at most `maxTextures` (`base` counts `baseTextures`).
    static func stack(_ layers: [CIImage], over base: CIImage, baseTextures: Int = 1, rasterScale: CGSize = CGSize(width: 1, height: 1)) -> CIImage {
        let layers = layers.filter { !$0.extent.isEmpty }.map(clipped)
        return stack(layers, over: base, baseTextures: baseTextures, texturesPerLayer: texturesPerLayer, rasterScale: rasterScale)
    }

    private static func stack(_ layers: [CIImage], over base: CIImage, baseTextures: Int, texturesPerLayer: Int, rasterScale: CGSize) -> CIImage {
        guard layers.count > max(1, (maxTextures - baseTextures) / texturesPerLayer) else {
            return layers.reduce(base) { $1.composited(over: $0) }
        }
        let runLength = max(1, maxTextures / texturesPerLayer)
        let runs = stride(from: 0, to: layers.count, by: runLength).map { start -> CIImage in
            let run = layers[start..<min(start + runLength, layers.count)]
            let bounds = run.reduce(CGRect.null) { $0.union($1.extent) }
            return ended(run.reduce(CIImage(color: .clear).cropped(to: bounds)) { $1.composited(over: $0) }, rasterScale: rasterScale)
        }
        // A run reads as one texture.
        return stack(runs, over: base, baseTextures: baseTextures, texturesPerLayer: 1, rasterScale: rasterScale)
    }
}
