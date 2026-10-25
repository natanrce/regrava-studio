import CoreImage
import Foundation
import RegravaCore

/// Hide sensitive data / Hide faces covers, drawn on the recording after the manual masks: text
/// under rounded rects in the colours around them, faces under blurred circles.
enum AutoMaskRenderer {
    private static let colorsKernel = RenderKernels.general("autoMaskColors")
    private static let applyKernel = RenderKernels.general("autoMaskApply")

    /// `frame` holds 0…1 rects of the full video; `image` is the recording after the screen
    /// crop `crop01` (pixels from its origin).
    static func apply(_ frame: AutoMaskFrame, to image: CIImage, crop01: Rect2, videoSize: Size2) -> CIImage {
        guard !frame.isEmpty, let colorsKernel, let applyKernel else { return image }
        let extent = image.extent
        let cropX = crop01.x * videoSize.width, cropTop = crop01.y * videoSize.height
        let cropHeight = extent.height
        /// A 0…1 top-left rect of the video → pixels of the cropped image, bottom-left origin.
        func pixels(_ r: Rect2) -> SIMD4<Float> {
            let x = r.x * videoSize.width - cropX
            let top = r.y * videoSize.height - cropTop
            let h = r.height * videoSize.height
            return SIMD4(Float(x + extent.minX), Float(cropHeight - top - h + extent.minY), Float(r.width * videoSize.width), Float(h))
        }
        var params = [SIMD4<Float>](repeating: .zero, count: 48)
        let text = Array(frame.bounds01.prefix(AutoMasks.maxTextBoxes))
        let faces = Array(frame.faceBounds01.prefix(AutoMasks.maxFaceBoxes))
        for (i, r) in text.enumerated() { params[i] = pixels(r) }
        for (i, r) in faces.enumerated() { params[32 + i] = pixels(r) }
        let data = params.withUnsafeBytes { Data($0) }
        let boxes = CIImage(bitmapData: data, bytesPerRow: 48 * 16, size: CGSize(width: 48, height: 1), format: .RGBAf, colorSpace: nil)
        let boxesRect = CGRect(x: 0, y: 0, width: 48, height: 1)
        let source = image.clampedToExtent()
        let colorsRect = CGRect(x: 0, y: 0, width: 64, height: 2)
        let colors = colorsKernel.apply(extent: colorsRect, roiCallback: { index, _ in index == 0 ? extent.insetBy(dx: -12, dy: -12) : boxesRect },
                                        arguments: [source, boxes, Float(text.count)]) ?? CIImage(color: .black).cropped(to: colorsRect)
        // One blur for every face, at the largest face's radius (`r·0.5`; the blur radius
        // maps to a Gaussian σ of about half of it).
        var blurred = image
        if let largest = faces.map({ max($0.width * videoSize.width, $0.height * videoSize.height) * 0.65 }).max() {
            blurred = source.applyingGaussianBlur(sigma: max(largest * 0.5 * 0.5, 1)).cropped(to: extent)
        }
        return applyKernel.apply(extent: extent, roiCallback: { index, rect in
            switch index {
            case 0, 1: return rect
            case 2: return boxesRect
            default: return colorsRect
            }
        }, arguments: [source, blurred.clampedToExtent(), boxes, colors, Float(text.count), Float(faces.count)]) ?? image
    }
}
