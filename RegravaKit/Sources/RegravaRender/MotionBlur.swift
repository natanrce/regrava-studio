import CoreImage
import Foundation
import RegravaCore

/// Motion blur: a moving layer is averaged along the trail between where it is now and
/// `lerp(now, previousFrame, strength)`, with `strength = motionBlurAmount × fps / 60`. Samples
/// where the layer is absent weigh more for the screen (`fp(alpha, 2) = 1 + 2·smoothstep(0, 1, 1
/// − alpha)`), so its trail fades out smoothly; the cursor and the camera average uniformly. How
/// much work a frame may take: export and paused frames use the full motion blur quality,
/// playback a lighter one.
public enum RenderQuality: Sendable {
    case export, pausedHigh, pausedLow, playing

    /// `qualityByMode`: most samples along a trail.
    var maxSamples: Int { self == .playing ? 6 : 16 }
    /// `fetchSpanTexelsByMode`: one sample every this many texels of travel.
    var texelsPerSample: Double { self == .export || self == .pausedHigh ? 4 : 16 }
}

enum MotionBlur {
    /// `smoothFalloffRatio` of the screen. The cursor and the camera use the default 0.
    static let screenFalloffRatio = 2.0

    private static let weightedKernel = RenderKernels.color("motionBlurWeighted")
    private static let weightKernel = RenderKernels.color("motionBlurWeight")
    private static let divideKernel = RenderKernels.color("motionBlurNormalize")

    /// Strength of the trail for the current settings.
    static func strength(amount: Double, fps: Double, disabled: Bool) -> Double {
        disabled ? 0 : amount * fps / 60
    }

    /// Number of samples for a trail `travel` canvas pixels long.
    static func sampleCount(travel: Double, quality: RenderQuality = .export) -> Int {
        Int(clamp((travel / quality.texelsPerSample).rounded(.up), 1, Double(quality.maxSamples)))
    }

    private static let trailKernel = RenderKernels.general("motionBlurTrail")

    /// A layer drawn at `now` averaged along its trail from `start` (Core Image rects), the
    /// reads at (k + phase) / samples of the way with the phase from 8×8 Bayer noise at each
    /// output pixel (`ditherRatio` 1), so steps between reads do not band. Colours average as
    /// squares of their encoded values.
    static func trail(_ layer: CIImage, now: CGRect, start: CGRect, samples: Int, bounds: CGRect, canvasHeight: Double, falloffRatio: Double = 0) -> CIImage? {
        guard samples > 1, let kernel = trailKernel, now.width > 0, now.height > 0 else { return nil }
        let encoded = layer.applyingFilter("CILinearToSRGBToneCurve")
        // Two clear pixels around the layer: reads past it land on them.
        let source = encoded.extent.insetBy(dx: -2, dy: -2)
        guard let out = kernel.apply(
            extent: bounds,
            roiCallback: { _, _ in source },
            arguments: [
                encoded,
                CIVector(cgRect: now),
                CIVector(cgRect: start),
                CIVector(x: CGFloat(samples), y: falloffRatio, z: canvasHeight, w: 0),
            ]
        ) else { return nil }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: bounds)
    }

    /// Averages `layer(t)` for t spread over the trail (0 = trail start, 1 = now), inside `bounds`.
    static func accumulate(samples: Int, bounds: CGRect, falloffRatio: Double = 0, layer: (Double) -> CIImage) -> CIImage? {
        guard samples > 1, let weighted = weightedKernel, let weightOnly = weightKernel, let divide = divideKernel else { return nil }
        let clear = CIImage(color: .clear).cropped(to: bounds)
        let ratio = NSNumber(value: falloffRatio)
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
