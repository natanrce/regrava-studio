import Foundation
import Testing
@testable import RegravaRender

struct PicoFaceDetectorTests {
    @Test func loadsTheBundledCascade() throws {
        let cascade = try #require(PicoCascade.bundled)
        #expect(cascade.depth == 6)
        #expect(cascade.trees == 468)
        // A flat image has no faces.
        let gray = [UInt8](repeating: 128, count: 200 * 150)
        #expect(cascade.detect(gray: gray, width: 200, height: 150, parameters: .init(minSize: 40, maxSize: 150)).isEmpty)
    }
}
