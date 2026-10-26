import CoreVideo
import Foundation

extension SD {
    /// Half-resolution luma of a decoded frame: every output pixel is the rounded mean of a 2×2 block
    /// of the frame's first (luma) plane, `(a + b + c + d + 2) >> 2`.
    static func makeHalfFrame(_ buffer: CVPixelBuffer, timeMs: Double, widthPx: Int, heightPx: Int) -> HalfFrame {
        let halfWidth = widthPx / 2
        let halfHeight = heightPx / 2
        var pixels = [UInt8](repeating: 0, count: halfWidth * halfHeight)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<halfHeight {
                let top = base + (y * 2) * rowBytes
                let bottom = top + rowBytes
                let row = y * halfWidth
                for x in 0..<halfWidth {
                    let sum = UInt32(top[2 * x]) + UInt32(top[2 * x + 1]) + UInt32(bottom[2 * x]) + UInt32(bottom[2 * x + 1])
                    out[row + x] = UInt8((sum + 2) >> 2)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        return HalfFrame(timeMs: timeMs, pixels: pixels)
    }
}
