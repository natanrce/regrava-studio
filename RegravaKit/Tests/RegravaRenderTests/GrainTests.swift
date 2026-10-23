import CoreImage
import Foundation
import Testing
@testable import RegravaRender

struct GrainTests {
    /// Grain shows on mid grey, not on black.
    @Test func addsMidtoneGrainOnly() throws {
        let kernel = try #require(RenderKernels.color("filmGrain"))
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        func spread(_ gray: CGFloat) throws -> Double {
            let input = CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: rect)
            let out = try #require(kernel.apply(extent: rect, arguments: [input, CIVector(x: 0.3, y: 7, z: 0, w: 0)]))
            var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
            CIContext(options: [.workingColorSpace: NSNull()]).render(out, toBitmap: &pixels, rowBytes: 64 * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
            let g = stride(from: 1, to: pixels.count, by: 4).map { Double(pixels[$0]) }
            let mean = g.reduce(0, +) / Double(g.count)
            return sqrt(g.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(g.count))
        }
        #expect(try spread(0.25) > 0.002)
        #expect(try spread(0) < 1e-6)
    }
}
