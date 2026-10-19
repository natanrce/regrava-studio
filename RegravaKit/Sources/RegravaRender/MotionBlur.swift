import CoreImage
import Foundation
import RegravaCore

/// Motion blur: a moving layer is averaged along the trail between where it is now and
/// `lerp(now, previousFrame, strength)`, with `strength = motionBlurAmount × fps / 60`. Samples
/// where the layer is absent weigh more (`fp(alpha, 2) = 1 + 2·smoothstep(0, 1, 1 − alpha)`), so
/// the trail fades out smoothly. How much work a frame may take: export and paused frames use
/// the full motion blur quality, playback a lighter one.
public enum RenderQuality: Sendable {
    case export, pausedHigh, pausedLow, playing

    /// `qualityByMode`: most samples along a trail.
    var maxSamples: Int { self == .playing ? 6 : 16 }
    /// `fetchSpanTexelsByMode`: one sample every this many texels of travel.
    var texelsPerSample: Double { self == .export || self == .pausedHigh ? 4 : 16 }
}

enum MotionBlur {
    /// `smoothFalloffRatio` used for the screen and the cursor.
    static let smoothFalloffRatio = 2.0

    private static let weightedKernel = RenderKernels.color("motionBlurWeighted")
    private static let weightKernel = RenderKernels.color("motionBlurWeight")
    private static let divideKernel = RenderKernels.color("motionBlurNormalize")

    /// Strength of the trail for the current settings.
    static func strength(amount: Double, fps: Int, disabled: Bool) -> Double {
        disabled ? 0 : amount * Double(fps) / 60
    }

    /// Number of samples for a trail `travel` canvas pixels long.
    static func sampleCount(travel: Double, quality: RenderQuality = .export) -> Int {
        Int(clamp((travel / quality.texelsPerSample).rounded(.up), 1, Double(quality.maxSamples)))
    }

    /// Averages `layer(t)` for t spread over the trail (0 = trail start, 1 = now), inside `bounds`.
    static func accumulate(samples: Int, bounds: CGRect, layer: (Double) -> CIImage) -> CIImage? {
        guard samples > 1, let weighted = weightedKernel, let weightOnly = weightKernel, let divide = divideKernel else { return nil }
        let clear = CIImage(color: .clear).cropped(to: bounds)
        let ratio = NSNumber(value: smoothFalloffRatio)
        var colorSum: CIImage?
        var weightSum: CIImage?
        for k in 0..<samples {
            let t = (Double(k) + 0.5) / Double(samples)
            let sample = layer(t).composited(over: clear).cropped(to: bounds)
            guard let color = weighted.apply(extent: bounds, arguments: [sample, ratio]),
                  let weight = weightOnly.apply(extent: bounds, arguments: [sample, ratio]) else { return nil }
            colorSum = colorSum.map { color.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? color
            weightSum = weightSum.map { weight.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? weight
        }
        guard let colorSum, let weightSum else { return nil }
        return divide.apply(extent: bounds, arguments: [colorSum, weightSum])
    }
}

extension Rect2 {
    /// Largest corner displacement between two rectangles.
    func cornerTravel(to other: Rect2) -> Double {
        let topLeft = hypot(x - other.x, y - other.y)
        let bottomRight = hypot(x + width - (other.x + other.width), y + height - (other.y + other.height))
        return max(topLeft, bottomRight)
    }

    /// Every edge within `tolerance`.
    func isClose(to other: Rect2, tolerance: Double) -> Bool {
        abs(x - other.x) < tolerance && abs(y - other.y) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
