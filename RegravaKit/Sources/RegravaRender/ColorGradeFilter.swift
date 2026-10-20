import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RegravaCore

/// The `lut3d-grade` processor on Core Image: trilinear lookup on sRGB-encoded values, mixed
/// with the source by the intensity.
public enum ColorGradeFilter {
    /// Cube data for Core Image with the intensity mix baked in: trilinear lookup of a cube
    /// mixed with the identity equals mixing the source with the graded colour.
    public static func cubeData(_ lut: ColorLUT, intensity: Double) -> Data {
        let n = lut.size
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let step = 1 / Float(n - 1), k = Float(min(max(intensity, 0), 1))
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = (b * n + g) * n + r
                    let identity = [Float(r) * step, Float(g) * step, Float(b) * step]
                    for c in 0..<3 {
                        values[i * 4 + c] = identity[c] + (Float(lut.texels[i * 4 + c]) / 255 - identity[c]) * k
                    }
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func apply(data: Data, size: Int, to image: CIImage) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = data
        filter.colorSpace = space
        return filter.outputImage ?? image
    }

    public static func apply(_ lut: ColorLUT, intensity: Double = 1, to image: CIImage) -> CIImage {
        apply(data: cubeData(lut, intensity: intensity), size: lut.size, to: image)
    }
}
