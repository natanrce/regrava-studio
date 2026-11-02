import CoreImage
import Testing
@testable import RegravaCore
@testable import RegravaRender

@Suite struct DebandTests {
    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return p
    }

    /// q × 4 eight-bit steps over ceil(q × 4) rounds (1…4): 2 and 2 at the default 0.5.
    @Test func qualityKnobs() {
        #expect(Deband.recordingKnobs(quality01: 0.5) == (2, 2))
        #expect(Deband.recordingKnobs(quality01: 0.1) == (0.4, 1))
        #expect(Deband.recordingKnobs(quality01: 1) == (4, 4))
        #expect(Deband.recordingKnobs(quality01: 0) == (0, 0))
        #expect(Deband.recordingKnobs(quality01: 2) == (4, 4))
    }

    /// Full strength to 10 px of motion, none from 30, smoothstep between in 1/16 steps.
    @Test func motionEasesTheThreshold() {
        #expect(Deband.motionStrength(0) == 1)
        #expect(Deband.motionStrength(10) == 1)
        #expect(Deband.motionStrength(20) == 0.5)
        #expect(Deband.motionStrength(30) == 0)
        // t = 0.25: 1 − 0.15625 = 0.84375, the nearest 1/16 is 0.875.
        #expect(Deband.motionStrength(15) == 0.875)
        // Edges moving the same way: the smaller move per axis; opposite ways: none.
        let now = Rect2(x: 10, y: 0, width: 100, height: 100)
        #expect(Deband.slowestPixelMotion(now, Rect2(x: 0, y: 0, width: 105, height: 100)) == 5)
        #expect(Deband.slowestPixelMotion(now, Rect2(x: 20, y: 0, width: 80, height: 100)) == 0)
    }

    /// Only export and high-quality pauses deband; a moving screen eases it out.
    @Test func recordingSettingsFollowQualityAndMotion() {
        let rect = Rect2(x: 0, y: 0, width: 100, height: 100)
        let still = Deband.recordingSettings(quality01: 0.5, motionBlurAmount: 1, screen: rect, before: rect, quality: .export)
        #expect(still == Deband.Settings(thresholdEightBitSteps: 2, radiusTexels: 16, iterations: 2))
        #expect(Deband.recordingSettings(quality01: 0.5, motionBlurAmount: 1, screen: rect, before: rect, quality: .playing).isOff)
        #expect(Deband.recordingSettings(quality01: 0.5, motionBlurAmount: 1, screen: rect, before: rect, quality: .pausedLow).isOff)
        let moved = Rect2(x: 40, y: 0, width: 100, height: 100)
        #expect(Deband.recordingSettings(quality01: 0.5, motionBlurAmount: 1, screen: moved, before: rect, quality: .pausedHigh).isOff)
        // The motion counts times the motion blur amount.
        #expect(!Deband.recordingSettings(quality01: 0.5, motionBlurAmount: 0.2, screen: moved, before: rect, quality: .pausedHigh).isOff)
    }

    /// A one-step band is smoothed; a hard edge far above the threshold is kept.
    @Test func smoothsBandsAndKeepsEdges() {
        let size = CGRect(x: 0, y: 0, width: 64, height: 64)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ v: CGFloat) -> CIImage { CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: space)!) }
        let banded = color(101.0 / 255).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64)).composited(over: color(100.0 / 255).cropped(to: size))
        let out = Deband.apply(banded, settings: .wallpaper)
        #expect(out.extent == size)
        // Next to the step, values land between the two levels (plus the dither).
        let near = (0..<8).map { pixel(out, 31, CGFloat(8 + $0))[0] * 255 }
        #expect(near.contains { $0 > 100.2 && $0 < 100.8 })
        let edge = color(0.2).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64)).composited(over: color(0.8).cropped(to: size))
        let kept = Deband.apply(edge, settings: .wallpaper)
        #expect(abs(pixel(kept, 31, 20)[0] - 0.8) < 0.01)
        #expect(abs(pixel(kept, 32, 20)[0] - 0.2) < 0.01)
    }
}
