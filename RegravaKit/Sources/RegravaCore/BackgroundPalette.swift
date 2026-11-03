import Foundation

// OKLCH colour helpers and the random background palette generator used by the
// "Randomize" buttons and the gradient "Hue" slider.

/// A colour in OKLCH: perceptual lightness 0…1, chroma, hue in degrees.
public struct OKLCH: Hashable, Sendable {
    public var lightness01: Double
    public var chroma: Double
    public var hueDegrees: Double

    public init(lightness01: Double, chroma: Double, hueDegrees: Double) {
        self.lightness01 = lightness01
        self.chroma = chroma
        self.hueDegrees = hueDegrees
    }
}

public enum OKLCHColor {
    /// Upper bound of the chroma search.
    static let maxChromaSearch = 0.4
    /// Per-channel slack when testing linear sRGB against 0…1.
    static let gamutEpsilon = 0.00001
    /// OKLab distance under which a clipped colour still counts as in gamut.
    static let gamutTolerance = 0.02

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : v > hi ? hi : v }

    private static func lab(_ c: OKLCH) -> (l: Double, a: Double, b: Double) {
        let h = c.hueDegrees * .pi / 180
        return (c.lightness01, c.chroma * cos(h), c.chroma * sin(h))
    }

    /// OKLCH to linear sRGB (unclamped).
    public static func linearRGB(_ c: OKLCH) -> (r: Double, g: Double, b: Double) {
        let (l, a, b) = lab(c)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.291485548 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        return (
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3
        )
    }

    /// Linear sRGB to OKLCH.
    public static func oklch(linear r: Double, _ g: Double, _ b: Double) -> OKLCH {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        let hue = (atan2(B, A) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return OKLCH(lightness01: L, chroma: hypot(A, B), hueDegrees: hue)
    }

    static func gammaEncode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    static func gammaDecode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// An sRGB colour (its 8-bit hex value) in OKLCH.
    public static func oklch(_ color: RGBA) -> OKLCH {
        func channel(_ v: Double) -> Double { gammaDecode(Double(Int((clamp(v, 0, 1) * 255).rounded())) / 255) }
        return oklch(linear: channel(color.r), channel(color.g), channel(color.b))
    }

    private static func isInGamut(_ c: OKLCH) -> Bool {
        let rgb = linearRGB(c)
        let e = gamutEpsilon
        if rgb.r >= -e && rgb.r <= 1 + e && rgb.g >= -e && rgb.g <= 1 + e && rgb.b >= -e && rgb.b <= 1 + e { return true }
        let clipped = oklch(linear: clamp(rgb.r, 0, 1), clamp(rgb.g, 0, 1), clamp(rgb.b, 0, 1))
        let p = lab(c), q = lab(clipped)
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return (dl * dl + da * da + db * db).squareRoot() < gamutTolerance
    }

    /// The largest displayable chroma at this lightness and hue (24-step bisection).
    public static func maxChroma(lightness01: Double, hueDegrees: Double) -> Double {
        var lo = 0.0, hi = maxChromaSearch
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if isInGamut(OKLCH(lightness01: lightness01, chroma: mid, hueDegrees: hueDegrees)) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Gamut-mapped sRGB colour, quantised to 8 bits per channel.
    public static func rgba(_ c: OKLCH) -> RGBA {
        let lightness = clamp(c.lightness01, 0, 1)
        let chroma = min(c.chroma, maxChroma(lightness01: lightness, hueDegrees: c.hueDegrees))
        let rgb = linearRGB(OKLCH(lightness01: lightness, chroma: chroma, hueDegrees: c.hueDegrees))
        func channel(_ v: Double) -> Double { (clamp(gammaEncode(v), 0, 1) * 255).rounded() / 255 }
        return RGBA(channel(rgb.r), channel(rgb.g), channel(rgb.b))
    }
}

extension BackgroundGradient {
    /// OKLCH hue of the first stop.
    public var hueDegrees: Double {
        guard let first = stops.first else { return 0 }
        return OKLCHColor.oklch(first.color).hueDegrees
    }

    /// Rotates every stop by the same hue delta so the first stop lands on `hueDegrees`,
    /// keeping each stop's lightness and its chroma relative to the displayable maximum.
    public func withHue(_ hueDegrees: Double) -> BackgroundGradient {
        let colors = stops.map { OKLCHColor.oklch($0.color) }
        guard let first = colors.first else { return self }
        let delta = hueDegrees - first.hueDegrees
        var result = self
        result.stops = zip(stops, colors).map { stop, c in
            let hue = ((c.hueDegrees + delta).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            let oldMax = OKLCHColor.maxChroma(lightness01: c.lightness01, hueDegrees: c.hueDegrees)
            let newMax = OKLCHColor.maxChroma(lightness01: c.lightness01, hueDegrees: hue)
            let relative = oldMax > 0 ? min(1, c.chroma / oldMax) : 0
            var s = stop
            s.color = OKLCHColor.rgba(OKLCH(lightness01: c.lightness01, chroma: relative * newMax, hueDegrees: hue))
            return s
        }
        return result
    }
}

/// Random harmonious palettes: weighted lightness/intensity bands and hue-step styles.
public enum BackgroundPalette {
    struct Band {
        var weight: Double
        var lightnessRange01: ClosedRange<Double>
        var intensityRange01: ClosedRange<Double>
    }

    struct Style {
        var weight: Double
        var minColorCount = 1
        var hueStepRangeDegrees: ClosedRange<Double>
        var isHueRangePerStep = false
        var lightnessTravelRange01: ClosedRange<Double>
        var preferredLightnessRange01: ClosedRange<Double>?
        var preferredIntensityRange01: ClosedRange<Double>?
        var stopLightnessBounds01: ClosedRange<Double>?
        var intensityJitter01: Double
    }

    static let bands: [Band] = [
        Band(weight: 0.35, lightnessRange01: 0.74...0.9, intensityRange01: 0.4...0.7),
        Band(weight: 0.4, lightnessRange01: 0.58...0.74, intensityRange01: 0.7...1),
        Band(weight: 0.25, lightnessRange01: 0.33...0.5, intensityRange01: 0.55...0.9),
    ]

    static let styles: [Style] = [
        Style(weight: 0.26, hueStepRangeDegrees: 25...75, lightnessTravelRange01: 0.06...0.16, intensityJitter01: 0.08),
        Style(weight: 0.2, hueStepRangeDegrees: 80...135, lightnessTravelRange01: 0.08...0.2, preferredIntensityRange01: 0.6...0.95, intensityJitter01: 0.08),
        Style(weight: 0.16, hueStepRangeDegrees: 5...30, lightnessTravelRange01: 0.3...0.55, preferredLightnessRange01: 0.45...0.62, intensityJitter01: 0.08),
        Style(weight: 0.16, hueStepRangeDegrees: 10...95, lightnessTravelRange01: 0.15...0.38, preferredLightnessRange01: 0.18...0.4, preferredIntensityRange01: 0.55...0.9, stopLightnessBounds01: 0.06...0.6, intensityJitter01: 0.1),
        Style(weight: 0.14, minColorCount: 3, hueStepRangeDegrees: 30...85, isHueRangePerStep: true, lightnessTravelRange01: 0.35...0.8, preferredLightnessRange01: 0.42...0.6, preferredIntensityRange01: 0.7...0.95, stopLightnessBounds01: 0.08...0.97, intensityJitter01: 0.15),
        Style(weight: 0.08, hueStepRangeDegrees: 0...30, lightnessTravelRange01: 0.1...0.45, preferredIntensityRange01: 0.04...0.25, stopLightnessBounds01: 0.15...0.95, intensityJitter01: 0.05),
    ]

    static let defaultStopLightnessBounds01 = 0.18...0.94
    static let stopLightnessClamp01 = 0.05...0.97
    /// Greens in this hue band look muddy when dark.
    static let avoidedHueBand = 80.0...150.0
    static let avoidedHueMaxLightness = 0.5

    /// Gradient sizes: 2 stops (55 %), 3 (25 %), 4 (12 %), 5 (8 %).
    static let colorCounts: [(weight: Double, count: Int)] = [(0.55, 2), (0.25, 3), (0.12, 4), (0.08, 5)]

    /// Optional fixed values; anything left nil is randomised.
    public struct Options: Sendable {
        public var lightness01: Double?
        public var intensity01: Double?
        public var baseHueDegrees: Double?
        public var lightnessTravel01: Double?
        public var hueStepDegrees: Double?

        public init(lightness01: Double? = nil, intensity01: Double? = nil, baseHueDegrees: Double? = nil, lightnessTravel01: Double? = nil, hueStepDegrees: Double? = nil) {
            self.lightness01 = lightness01
            self.intensity01 = intensity01
            self.baseHueDegrees = baseHueDegrees
            self.lightnessTravel01 = lightnessTravel01
            self.hueStepDegrees = hueStepDegrees
        }
    }

    /// Random number source returning values in 0..<1.
    public typealias Random = () -> Double

    public static let systemRandom: Random = { Double.random(in: 0..<1) }

    static func uniform(_ range: ClosedRange<Double>, _ random: Random) -> Double {
        random() * (range.upperBound - range.lowerBound) + range.lowerBound
    }

    static func pickWeighted<T>(_ items: [T], weight: (T) -> Double, _ random: Random) -> T {
        var total = 0.0
        var index = -1
        for (i, item) in items.enumerated() {
            let w = weight(item)
            total += w
            if random() * total < w { index = i }
        }
        return items[max(index, 0)]
    }

    static func sign(_ random: Random) -> Double { random() < 0.5 ? -1 : 1 }

    static func normalizedHue(_ h: Double) -> Double { (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }

    /// Travel limited so the stops stay inside `bounds` around `lightness`.
    static func limitedTravel(_ travel: Double, lightness: Double, bounds: ClosedRange<Double>) -> Double {
        let room = 2 * max(0, min(lightness - bounds.lowerBound, bounds.upperBound - lightness))
        return min(travel, room)
    }

    static func isAvoided(lightness: Double, hue: Double) -> Bool {
        lightness < avoidedHueMaxLightness && hue > avoidedHueBand.lowerBound && hue < avoidedHueBand.upperBound
    }

    static func baseHue(lightness: Double, _ random: Random) -> Double {
        if lightness >= avoidedHueMaxLightness { return uniform(0...360, random) }
        let width = avoidedHueBand.upperBound - avoidedHueBand.lowerBound
        return normalizedHue(avoidedHueBand.upperBound + uniform(0...(360 - width), random))
    }

    /// A random number of gradient stops.
    public static func randomColorCount(_ random: Random = systemRandom) -> Int {
        pickWeighted(colorCounts, weight: \.weight, random).count
    }

    /// `count` related colours.
    public static func colors(_ count: Int, options: Options = Options(), random: Random = systemRandom) -> [RGBA] {
        guard count >= 1 else { return [] }
        let style = pickWeighted(styles.filter { count >= $0.minColorCount }, weight: \.weight, random)
        let band = pickWeighted(bands, weight: \.weight, random)
        let lightness = options.lightness01 ?? uniform(style.preferredLightnessRange01 ?? band.lightnessRange01, random)
        let intensity = options.intensity01 ?? uniform(style.preferredIntensityRange01 ?? band.intensityRange01, random)
        let base = options.baseHueDegrees ?? baseHue(lightness: lightness, random)
        let bounds = options.lightness01 != nil || options.lightnessTravel01 != nil
            ? defaultStopLightnessBounds01
            : style.stopLightnessBounds01 ?? defaultStopLightnessBounds01
        let travel: Double
        if let fixed = options.lightnessTravel01 {
            travel = (fixed > 0 ? 1 : fixed < 0 ? -1 : 0) * limitedTravel(abs(fixed), lightness: lightness, bounds: bounds)
        } else {
            travel = limitedTravel(uniform(style.lightnessTravelRange01, random), lightness: lightness, bounds: bounds) * sign(random)
        }
        let indices = Array(0..<count)
        let lightnesses = indices.map { i -> Double in
            let t = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let v = lightness + (t - 0.5) * travel
            return min(max(v, stopLightnessClamp01.lowerBound), stopLightnessClamp01.upperBound)
        }
        func hitsAvoidedBand(_ step: Double) -> Bool {
            indices.contains { isAvoided(lightness: lightnesses[$0], hue: normalizedHue(base + Double($0) * step)) }
        }
        let hueStep: Double
        if let fixed = options.hueStepDegrees {
            hueStep = fixed
        } else {
            let scale = style.isHueRangePerStep ? 1 : 1 / Double(max(1, count - 1))
            let step = uniform(style.hueStepRangeDegrees, random) * scale * sign(random)
            hueStep = hitsAvoidedBand(step) && !hitsAvoidedBand(-step) ? -step : step
        }
        let intensities = indices.map { _ -> Double in
            if let fixed = options.intensity01 { return fixed }
            let jitter = style.intensityJitter01
            return min(max(intensity + uniform(-jitter...jitter, random), 0.02), 1)
        }
        return indices.map { i in
            let l = lightnesses[i]
            let hue = normalizedHue(base + Double(i) * hueStep)
            return OKLCHColor.rgba(OKLCH(lightness01: l, chroma: intensities[i] * OKLCHColor.maxChroma(lightness01: l, hueDegrees: hue), hueDegrees: hue))
        }
    }

    /// A random gradient of 2–5 evenly spread stops.
    public static func randomGradient(_ random: Random = systemRandom) -> BackgroundGradient {
        BackgroundGradient(colors: colors(randomColorCount(random), random: random))
    }
}
