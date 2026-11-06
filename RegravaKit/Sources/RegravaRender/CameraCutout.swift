import CoreImage
import CoreVideo
import Foundation
import RegravaCore

extension CameraCutout {
    /// A stored or computed matte (`FrameMatter.width`×`height` bytes, rows from the top) as a
    /// one-channel image.
    static func matteImage(_ matte: [UInt8]) -> CIImage? {
        let width = FrameMatter.width, height = FrameMatter.height
        guard matte.count == width * height else { return nil }
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent8, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        matte.withUnsafeBytes { bytes in
            for y in 0..<height { memcpy(base + y * rowBytes, bytes.baseAddress! + y * width, width) }
        }
        return CIImage(cvPixelBuffer: buffer)
    }
}

/// The masked-video passes on Core Image. Mip-level averages are box means of the same footprint.
enum CameraCutout {
    private static let matteKernel = RenderKernels.general("cutoutMatteAlpha")
    private static let edgeKernel = RenderKernels.general("cutoutEdge")
    private static let coarseKernel = RenderKernels.general("cutoutForegroundCoarse")
    private static let foregroundKernel = RenderKernels.general("cutoutForeground")

    /// `frame` has its origin at 0. `matte` covers `window` (0…1 of the frame, from the top);
    /// outside it nothing is kept. `reveal01` = 1 − cutout01; `density` 0.5 while playing
    /// (`densityRatio`). Returns the premultiplied person (or the revealed frame).
    static func apply(frame source: CIImage, matte: CIImage, window: CGRect = PersonWindow.wholeFrame, edge: CameraBackgroundConfig, reveal01: Double, crop01: Rect2?, density: Double) -> CIImage {
        let reveal = clamp(reveal01, 0, 1)
        guard reveal < 1, let matteKernel, let edgeKernel, let coarseKernel, let foregroundKernel else { return source }
        let frameH = source.extent.height
        let frame = density == 1 ? source : source.transformed(by: CGAffineTransform(scaleX: density, y: density))
        let bounds = frame.extent
        let W = bounds.width, H = bounds.height
        let matteRect = FrameMatter.windowRect(window, in: bounds)
        let matteScaled = matte
            .transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: matteRect.width / matte.extent.width, y: matteRect.height / matte.extent.height))
            .transformed(by: CGAffineTransform(translationX: matteRect.minX, y: matteRect.minY))
        let texel = CGPoint(x: matteRect.width / matte.extent.width, y: matteRect.height / matte.extent.height)
        let clampedFrame = frame.clampedToExtent()

        // Matte → alpha at frame resolution (`compositeMatte`).
        guard let alpha = matteKernel.apply(
            extent: bounds,
            roiCallback: { _, r in r.insetBy(dx: -3 * texel.x - 2, dy: -3 * texel.y - 2) },
            arguments: [clampedFrame, matteScaled.clampedToExtent(), CIVector(x: texel.x, y: texel.y), CIVector(cgRect: matteRect)]
        ) else { return source }

        // Pass 1: inset and softness (the reveal is left to pass 3, which always runs here).
        let s = density
        let texelScale = max(1, frameH / matte.extent.height)
        let insetPx = max(0, edge.edgeInsetPx)
        let solidRadius = max(8 * texelScale, 4 * insetPx) * s
        let alphaMip = boxMean(alpha, size: solidRadius)
        let window = revealWindow(crop01)
        let wPx = max(1, window.width * W), hPx = max(1, window.height * H), d = hypot(wPx, hPx)
        let norm = CGPoint(x: 2 * wPx / d, y: 2 * hPx / d)
        guard let compose = edgeKernel.apply(
            extent: bounds,
            roiCallback: { _, r in r.insetBy(dx: -max(2 * texelScale * s, insetPx * s) - 2, dy: -max(2 * texelScale * s, insetPx * s) - 2) },
            arguments: [
                clampedFrame, alpha.clampedToExtent(), alphaMip,
                CIVector(x: clamp(edge.edgeFalloff01, 0, 1), y: 0, z: insetPx * s, w: texelScale * s),
                CIVector(x: W, y: H, z: norm.x, w: norm.y),
                CIVector(cgRect: window),
            ]
        ) else { return source }

        // Passes 2 and 3: colour decontamination of partial pixels, then the reveal.
        let meanSize = (90.0 / 1080) * frameH * s
        let composeMean = boxMean(compose, size: meanSize)
        let footageMean = boxMean(frame, size: meanSize)
        guard let coarse = coarseKernel.apply(
            extent: bounds,
            roiCallback: { _, r in r },
            arguments: [compose.clampedToExtent(), clampedFrame, composeMean, footageMean]
        ) else { return compose }
        let personSize = (24.0 / 1080) * frameH * s
        let personMean = boxMean(coarse, size: personSize)
        let wideMean = boxMean(coarse, size: personSize * 8)
        return foregroundKernel.apply(
            extent: bounds,
            roiCallback: { _, r in r },
            arguments: [compose.clampedToExtent(), clampedFrame, composeMean, footageMean, personMean, wideMean,
                        CIVector(x: reveal, y: norm.x, z: norm.y, w: 0), CIVector(cgRect: window), CIVector(x: W, y: H)]
        ) ?? compose
    }

    /// The crop window in Core Image's bottom-up unit space.
    private static func revealWindow(_ crop01: Rect2?) -> CGRect {
        let c = crop01 ?? Rect2(x: 0, y: 0, width: 1, height: 1)
        return CGRect(x: c.x, y: 1 - c.y - c.height, width: max(c.width, 1e-6), height: max(c.height, 1e-6))
    }

    /// Mean over a `size`-pixel box, standing in for a mip level of that footprint.
    private static func boxMean(_ image: CIImage, size: Double) -> CIImage {
        guard size > 1.5 else { return image.clampedToExtent() }
        return image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: size / 2])
    }
}
