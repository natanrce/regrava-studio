import Foundation

// Camera colour grading: a look generator and look definitions. Every grade becomes a 33³
// 8-bit LUT on sRGB-encoded values.

/// A 3D LUT: RGBA8 texels, red fastest, then green, then blue (`.cube` order).
public struct ColorLUT: Equatable, Sendable {
    public var size: Int
    public var texels: [UInt8]

    public init(size: Int, texels: [UInt8]) {
        self.size = size
        self.texels = texels
    }

    public enum ParseError: Error, Equatable {
        case oneDimensional, missingSize, notEnoughEntries
    }

    /// `.cube` parser: domain-normalised, quantised to 8 bits.
    public init(cube text: String) throws {
        var size = 0
        var domainMin = [0.0, 0, 0], domainMax = [1.0, 1, 1]
        var values: [[Double]] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            if line.hasPrefix("LUT_1D_SIZE") { throw ParseError.oneDimensional }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.dropFirst(11).trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                let triple = parts.dropFirst().compactMap { Double($0) }
                if triple.count == 3 { if line.hasPrefix("DOMAIN_MIN") { domainMin = triple } else { domainMax = triple } }
                continue
            }
            guard parts.count == 3 else { continue }
            let triple = parts.compactMap { Double($0) }
            if triple.count == 3 { values.append(triple) }
        }
        guard size >= 2 else { throw ParseError.missingSize }
        let count = size * size * size
        guard values.count >= count else { throw ParseError.notEnoughEntries }
        var texels = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            for c in 0..<3 {
                let v = (values[i][c] - domainMin[c]) / max(domainMax[c] - domainMin[c], 1e-6)
                texels[i * 4 + c] = UInt8((min(max(v, 0), 1) * 255).rounded())
            }
        }
        self.init(size: size, texels: texels)
    }

    /// `.cube` writer.
    public func cube(title: String, comments: [String]) -> String {
        var lines = ["TITLE \"\(title)\""] + comments.map { "# \($0)" } + ["", "LUT_3D_SIZE \(size)", ""]
        lines.reserveCapacity(lines.count + size * size * size)
        for i in 0..<(size * size * size) {
            lines.append((0..<3).map { String(format: "%.6f", Double(texels[i * 4 + $0]) / 255) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A look definition (`lookDefinitions.ts`). `maxSkinHueShiftDeg`/`maxNeighborDelta` are data only.
public struct ColorLook: Sendable {
    public struct HueRegion: Sendable {
        public var centerDeg: Double
        public var widthDeg: Double
        public var hueShiftDeg = 0.0
        public var chromaScale = 1.0
        public var lightnessShift = 0.0
        public var taperAboveChroma: Double?
    }

    public struct Tone: Sendable {
        public var hueDeg: Double
        public var amount: Double
    }

    public var name: String
    public var description: String
    public var temperature = 0.0
    public var tint = 0.0
    public var exposureEv = 0.0
    public var toneCurve: [(x: Double, y: Double)]?
    public var perChannelMix = 0.5
    public var hueRegions: [HueRegion] = []
    public var saturation = 1.0
    public var vibrance = 0.0
    public var chromaPop = 0.0
    public var colorDensity = 0.0
    public var satByLumaShadows = 1.0
    public var satByLumaHighlights = 1.0
    public var splitShadows: Tone?
    public var splitHighlights: Tone?
    public var skinRefineHueConvergence = 0.0
    public var skinRefineChromaTame = 0.0
    public var skinRefineTargetHueOffsetDeg = 3.0
    public var skinProtection: Double
    public var monochromeWeights: (Double, Double, Double)?
    public var monochromeTint: Tone?

    public init(name: String, description: String, skinProtection: Double) {
        self.name = name
        self.description = description
        self.skinProtection = skinProtection
    }
}

public enum ColorGrading {
    public static let lutSize = 33

    // MARK: Constants

    static let skinChromaKnee = 0.11
    static let colorDensityMaxDrop = 0.1
    static let lumaWeights = (0.2126, 0.7152, 0.0722)

    /// Circular mean of the OKLab hues of seven skin swatches, ≈ 62.0931°.
    public static let skinCenterHueDeg: Double = {
        let swatches: [(Double, Double, Double)] = [(177, 146, 127), (168, 137, 118), (241, 194, 125), (224, 172, 105), (198, 134, 66), (141, 85, 36), (92, 55, 27)]
        var s = 0.0, c = 0.0
        for rgb in swatches {
            let lab = oklab(fromLinear: linear(fromSrgb: (rgb.0 / 255, rgb.1 / 255, rgb.2 / 255)))
            let h = atan2(lab.2, lab.1)
            s += sin(h)
            c += cos(h)
        }
        return hueDeg(a: c, b: s)
    }()

    // MARK: Helpers

    typealias V3 = (Double, Double, Double)

    static func decode(_ e: Double) -> Double { e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4) }
    static func encode(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }
    static func linear(fromSrgb v: V3) -> V3 { (decode(v.0), decode(v.1), decode(v.2)) }
    static func srgb(fromLinear v: V3) -> V3 { (encode(v.0), encode(v.1), encode(v.2)) }
    private static func cbrt(_ v: Double) -> Double { pow(max(v, 0), 1.0 / 3) }

    static func oklab(fromLinear rgb: V3) -> V3 {
        let l = cbrt(0.4122214708 * rgb.0 + 0.5363325363 * rgb.1 + 0.0514459929 * rgb.2)
        let m = cbrt(0.2119034982 * rgb.0 + 0.6806995451 * rgb.1 + 0.1073969566 * rgb.2)
        let s = cbrt(0.0883024619 * rgb.0 + 0.2817188376 * rgb.1 + 0.6299787005 * rgb.2)
        return (
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        )
    }

    static func linear(fromOklab lab: V3) -> V3 {
        let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
        let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
        let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.291485548 * lab.2, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
        )
    }

    static func hueDeg(a: Double, b: Double) -> Double {
        if abs(a) + abs(b) < 1e-7 { return 0 }
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = fmod(abs(a - b), 360)
        return d > 180 ? 360 - d : d
    }

    static func gaussian(_ d: Double, _ sigma: Double) -> Double { exp(-(d * d) / (2 * sigma * sigma)) }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
    private static func clamp01(_ v: V3) -> V3 { (clamp01(v.0), clamp01(v.1), clamp01(v.2)) }

    static func skinWeight(L: Double, chroma: Double, hueDeg h: Double) -> Double {
        let hue = gaussian(hueDistance(h, skinCenterHueDeg), 20)
        let c = smoothstep(0.015, 0.05, chroma) * (1 - smoothstep(0.16, 0.26, chroma))
        let l = smoothstep(0.1, 0.25, L) * (1 - smoothstep(0.94, 1, L))
        return hue * c * l
    }

    static func compressIntoGamut(_ lab: V3) -> V3 { clamp01(linear(fromOklab: (clamp01(lab.0), lab.1, lab.2))) }

    // MARK: Look → settings

    struct Settings {
        var points: [(x: Double, y: Double, tangent: Double)] = []
        var perChannelMix = 0.5
        var regions: [ColorLook.HueRegion] = []
        var whiteBalanceGains: V3 = (1, 1, 1)
        var exposureGain = 1.0
        var saturation = 1.0, vibrance = 0.0, chromaPop = 0.0, colorDensity = 0.0
        var satByLumaShadows = 1.0, satByLumaHighlights = 1.0
        var splitShadows = (0.0, 0.0), splitHighlights = (0.0, 0.0)
        var skinProtection = 0.0
        var skinRefineHueConvergence = 0.0, skinRefineTargetHueDeg = 0.0, skinRefineChromaTame = 0.0
        var monochromeWeights: V3?
        var monochromeTint: (Double, Double)?
    }

    /// Fritsch–Carlson tangents capped at radius 3.
    static func toneCurveTangents(_ points: [(x: Double, y: Double)]) -> [Double] {
        let n = points.count - 1
        var d: [Double] = []
        for i in 0..<n { d.append((points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x)) }
        var m = [d[0]]
        for i in 1..<max(n, 1) where i < n { m.append(d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2) }
        m.append(d[n - 1])
        for i in 0..<n {
            if d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = hypot(a, b)
            if h > 3 {
                m[i] = 3 * a / h * d[i]
                m[i + 1] = 3 * b / h * d[i]
            }
        }
        return m
    }

    private static func tone(_ t: ColorLook.Tone?) -> (Double, Double) {
        guard let t else { return (0, 0) }
        return (cos(t.hueDeg * .pi / 180) * t.amount, sin(t.hueDeg * .pi / 180) * t.amount)
    }

    static func settings(_ look: ColorLook) -> Settings {
        var s = Settings()
        if let curve = look.toneCurve {
            let tangents = toneCurveTangents(curve)
            s.points = zip(curve, tangents).map { ($0.x, $0.y, $1) }
        }
        s.perChannelMix = look.perChannelMix
        s.regions = Array(look.hueRegions.prefix(6))
        let T = look.temperature, t = look.tint
        s.whiteBalanceGains = (1 + 0.14 * T - 0.04 * t, 1 + 0.08 * t, 1 - 0.14 * T - 0.04 * t)
        s.exposureGain = pow(2, look.exposureEv)
        s.saturation = look.saturation
        s.vibrance = look.vibrance
        s.chromaPop = look.chromaPop
        s.colorDensity = look.colorDensity
        s.satByLumaShadows = look.satByLumaShadows
        s.satByLumaHighlights = look.satByLumaHighlights
        s.splitShadows = tone(look.splitShadows)
        s.splitHighlights = tone(look.splitHighlights)
        s.skinProtection = look.skinProtection
        s.skinRefineHueConvergence = look.skinRefineHueConvergence
        s.skinRefineTargetHueDeg = skinCenterHueDeg + look.skinRefineTargetHueOffsetDeg
        s.skinRefineChromaTame = look.skinRefineChromaTame
        if let w = look.monochromeWeights {
            let sum = w.0 + w.1 + w.2
            s.monochromeWeights = (w.0 / sum, w.1 / sum, w.2 / sum)
            s.monochromeTint = look.monochromeTint.map { tone($0) }
        }
        return s
    }

    /// Cubic Hermite through the points, clamped.
    static func toneCurve(_ s: Settings, _ x: Double) -> Double {
        let pts = s.points
        if x <= pts[0].x { return clamp01(pts[0].y) }
        if x >= pts[pts.count - 1].x { return clamp01(pts[pts.count - 1].y) }
        var seg = 0
        let last = pts.count - 2
        for _ in 0..<8 where seg < last && x > pts[seg + 1].x { seg += 1 }
        let p = pts[seg], q = pts[seg + 1]
        let w = q.x - p.x, t = (x - p.x) / w, t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p.y + (t3 - 2 * t2 + t) * w * p.tangent + (-2 * t3 + 3 * t2) * q.y + (t3 - t2) * w * q.tangent
        return clamp01(y)
    }

    // MARK: Transform (`$transformLookColor`)

    static func transform(_ s: Settings, _ input: V3) -> V3 {
        var lin = linear(fromSrgb: input)

        if let weights = s.monochromeWeights {
            let gray = max(lin.0 * weights.0 + lin.1 * weights.1 + lin.2 * weights.2, 0)
            var encodedGray = encode(gray)
            if !s.points.isEmpty { encodedGray = toneCurve(s, encodedGray) }
            guard let tint = s.monochromeTint else { return (encodedGray, encodedGray, encodedGray) }
            let L = oklab(fromLinear: (decode(encodedGray), decode(encodedGray), decode(encodedGray))).0
            let w = smoothstep(0.02, 0.35, L) * (1 - smoothstep(0.75, 0.98, L))
            return srgb(fromLinear: compressIntoGamut((L, tint.0 * w, tint.1 * w)))
        }

        // White balance (luma-preserving) and exposure.
        let lumaBefore = lin.0 * 0.2126 + lin.1 * 0.7152 + lin.2 * 0.0722
        var balanced = (lin.0 * s.whiteBalanceGains.0, lin.1 * s.whiteBalanceGains.1, lin.2 * s.whiteBalanceGains.2)
        let lumaAfter = balanced.0 * 0.2126 + balanced.1 * 0.7152 + balanced.2 * 0.0722
        let norm = lumaAfter > 1e-8 ? lumaBefore / lumaAfter : 1
        balanced = (balanced.0 * norm, balanced.1 * norm, balanced.2 * norm)
        lin = (balanced.0 * s.exposureGain, balanced.1 * s.exposureGain, balanced.2 * s.exposureGain)
        var enc = clamp01(srgb(fromLinear: (min(lin.0, 8), min(lin.1, 8), min(lin.2, 8))))

        if !s.points.isEmpty {
            let perChannel = (toneCurve(s, enc.0), toneCurve(s, enc.1), toneCurve(s, enc.2))
            let luma = enc.0 * 0.2126 + enc.1 * 0.7152 + enc.2 * 0.0722
            let curved = toneCurve(s, luma)
            let delta = curved - luma
            var lumaOnly = enc
            if delta >= 0 {
                let k = 1 - luma > 0.0001 ? delta / (1 - luma) : 0
                lumaOnly = (enc.0 + (1 - enc.0) * k, enc.1 + (1 - enc.1) * k, enc.2 + (1 - enc.2) * k)
            } else {
                let g = luma > 0.0001 ? curved / luma : 1
                lumaOnly = (enc.0 * g, enc.1 * g, enc.2 * g)
            }
            let pre = oklab(fromLinear: linear(fromSrgb: enc))
            let preSkin = skinWeight(L: pre.0, chroma: hypot(pre.1, pre.2), hueDeg: hueDeg(a: pre.1, b: pre.2))
            let m = s.perChannelMix * (1 - s.skinProtection * preSkin)
            enc = (mix(lumaOnly.0, perChannel.0, m), mix(lumaOnly.1, perChannel.1, m), mix(lumaOnly.2, perChannel.2, m))
        }

        let lab0 = oklab(fromLinear: linear(fromSrgb: enc))
        var L = lab0.0, chroma = hypot(lab0.1, lab0.2), hue = hueDeg(a: lab0.1, b: lab0.2)
        let preRefine = skinWeight(L: L, chroma: chroma, hueDeg: hue)

        let toTarget = fmod(s.skinRefineTargetHueDeg - hue + 540, 360) - 180
        hue += toTarget * s.skinRefineHueConvergence * preRefine
        chroma -= max(chroma - skinChromaKnee, 0) * s.skinRefineChromaTame * preRefine

        let anchor = (L, cos(hue * .pi / 180) * chroma, sin(hue * .pi / 180) * chroma)
        let skin = skinWeight(L: L, chroma: chroma, hueDeg: hue)

        if !s.regions.isEmpty {
            var shift = 0.0, scale = 1.0, lightness = 0.0
            for r in s.regions {
                var w = gaussian(hueDistance(hue, r.centerDeg), r.widthDeg) * smoothstep(0.008, 0.04, chroma)
                if let taper = r.taperAboveChroma, taper >= 0 { w *= 1 - smoothstep(taper, taper + 0.08, chroma) }
                shift += r.hueShiftDeg * w
                scale *= 1 + (r.chromaScale - 1) * w
                lightness += r.lightnessShift * w
            }
            hue += shift
            chroma *= scale
            L += lightness
        }

        chroma *= s.saturation
        chroma *= 1 + s.vibrance * (1 - smoothstep(0, 0.13, chroma))
        chroma *= 1 + s.chromaPop * smoothstep(0.09, 0.26, chroma)

        let shadowW = 1 - smoothstep(0, 0.42, L)
        let highlightW = smoothstep(0.68, 1, L)
        chroma *= mix(1, s.satByLumaShadows, shadowW) * mix(1, s.satByLumaHighlights, highlightW)

        L -= s.colorDensity * colorDensityMaxDrop * smoothstep(0.04, 0.3, chroma) * smoothstep(0.06, 0.35, L)

        var a = cos(hue * .pi / 180) * chroma, b = sin(hue * .pi / 180) * chroma
        let neutrality = 1 - smoothstep(0.055, 0.14, chroma)
        let splitShadowW = (1 - smoothstep(0.06, 0.55, L)) * neutrality
        a += s.splitShadows.0 * splitShadowW
        b += s.splitShadows.1 * splitShadowW
        let splitHighlightW = smoothstep(0.55, 0.95, L) * neutrality
        a += s.splitHighlights.0 * splitHighlightW
        b += s.splitHighlights.1 * splitHighlightW

        let protection = s.skinProtection * skin
        if protection > 0 {
            L = mix(L, anchor.0, protection)
            a = mix(a, anchor.1, protection)
            b = mix(b, anchor.2, protection)
        }
        return clamp01(srgb(fromLinear: compressIntoGamut((L, a, b))))
    }

    /// The 33³ table of a look, quantised like `pack4x8unorm`.
    public static func lut(for look: ColorLook) -> ColorLUT {
        let s = settings(look)
        let n = lutSize
        var texels = [UInt8](repeating: 255, count: n * n * n * 4)
        let step = 1.0 / Double(n - 1)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let out = transform(s, (Double(ri) * step, Double(gi) * step, Double(bi) * step))
                    let i = ((bi * n + gi) * n + ri) * 4
                    texels[i] = UInt8((clamp01(out.0) * 255).rounded())
                    texels[i + 1] = UInt8((clamp01(out.1) * 255).rounded())
                    texels[i + 2] = UInt8((clamp01(out.2) * 255).rounded())
                }
            }
        }
        return ColorLUT(size: n, texels: texels)
    }

    /// `.cube` of a built-in look.
    public static func builtInCube(for look: ColorLook) -> String {
        lut(for: look).cube(title: look.name, comments: [
            look.description,
            "Part of the built-in Regrava Studio color grading looks.",
            "Display-referred: expects and outputs standard sRGB (Rec.709 primaries).",
        ])
    }

    /// Display name of a LUT asset: without the `-<10 alphanumerics>.cube` suffix.
    public static func displayName(ofAsset name: String) -> String {
        name.replacingOccurrences(of: "-[a-zA-Z0-9]{10}\\.cube$", with: "", options: .regularExpression)
    }
}
