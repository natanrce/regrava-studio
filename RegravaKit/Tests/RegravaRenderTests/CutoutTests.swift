import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct CutoutTests {
    let frame = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
    /// Person on the left half of a 256×144 matte.
    let matte = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 144))
        .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 144)))

    func alpha(_ image: CIImage, x: CGFloat, y: CGFloat = 180) -> UInt8 {
        var p = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return p[3]
    }

    @Test func keepsThePersonAndDropsTheBackground() {
        let out = CameraCutout.apply(frame: frame, matte: matte, edge: CameraBackgroundConfig(), reveal01: 0, crop01: nil, density: 1)
        #expect(out.extent == frame.extent)
        #expect(alpha(out, x: 100) > 250)
        #expect(alpha(out, x: 540) < 5)
    }

    @Test func revealBringsBackTheFrameFromTheCentre() {
        let full = CameraCutout.apply(frame: frame, matte: matte, edge: CameraBackgroundConfig(), reveal01: 1, crop01: nil, density: 1)
        #expect(alpha(full, x: 540) == 255)
        let half = CameraCutout.apply(frame: frame, matte: matte, edge: CameraBackgroundConfig(), reveal01: 0.5, crop01: nil, density: 1)
        // The circle grows from the middle; its strength is reveal01 (`getRevealAt`).
        #expect(abs(Int(alpha(half, x: 330)) - 128) <= 2)
        #expect(alpha(half, x: 636, y: 4) < 10)
    }

    @Test func edgeInsetShrinksThePerson() {
        var edge = CameraBackgroundConfig()
        let plain = CameraCutout.apply(frame: frame, matte: matte, edge: edge, reveal01: 0, crop01: nil, density: 1)
        edge.edgeInsetPx = 8
        let inset = CameraCutout.apply(frame: frame, matte: matte, edge: edge, reveal01: 0, crop01: nil, density: 1)
        #expect(alpha(inset, x: 316) < alpha(plain, x: 316))
    }

    @Test func visionMatteRunsOnAnyFrame() {
        // No person in a flat frame: either no matte or an empty one, never a crash.
        if let m = PersonMatter.shared.matte(for: frame, quality: .playing) {
            #expect(m.extent.width > 0)
        }
    }
}
