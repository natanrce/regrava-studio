import Foundation

// The 12 built-in looks, in picker order.

private func region(_ center: Double, _ width: Double, shift: Double = 0, chroma: Double = 1, lightness: Double = 0, taper: Double? = nil) -> ColorLook.HueRegion {
    ColorLook.HueRegion(centerDeg: center, widthDeg: width, hueShiftDeg: shift, chromaScale: chroma, lightnessShift: lightness, taperAboveChroma: taper)
}

private func tone(_ hue: Double, _ amount: Double) -> ColorLook.Tone { ColorLook.Tone(hueDeg: hue, amount: amount) }

private func look(_ name: String, _ description: String, skinProtection: Double, _ configure: (inout ColorLook) -> Void) -> ColorLook {
    var l = ColorLook(name: name, description: description, skinProtection: skinProtection)
    configure(&l)
    return l
}

public extension ColorGrading {
    static let builtInLooks: [ColorLook] = [
        look("Studio", "The 'make it look finished' default: evened-out skin, gentle filmic contrast, a breath of density and a whisper of warm-vs-cool separation. Enhancement, not a style.", skinProtection: 0.75) {
            $0.toneCurve = [(0, 0), (0.08, 0.06), (0.45, 0.49), (0.9, 0.925), (1, 1)]
            $0.perChannelMix = 0.5
            $0.skinRefineHueConvergence = 0.5; $0.skinRefineChromaTame = 0.35
            $0.vibrance = 0.16; $0.colorDensity = 0.4
            $0.satByLumaShadows = 0.9; $0.satByLumaHighlights = 0.95
            $0.splitShadows = tone(250, 0.012); $0.splitHighlights = tone(70, 0.008)
        },
        look("Cinema", "The blockbuster grade, done with conviction: shadows and blues dive into teal, greens fold in behind, skin stays warm and full on its line. Instant subject-background separation.", skinProtection: 0.93) {
            $0.toneCurve = [(0, 0.006), (0.1, 0.07), (0.48, 0.5), (0.9, 0.93), (1, 1)]
            $0.perChannelMix = 0.45
            $0.hueRegions = [
                region(230, 45, shift: -14, chroma: 1.12, lightness: -0.015),
                region(150, 40, shift: 16, chroma: 0.95, taper: 0.2),
                region(ColorGrading.skinCenterHueDeg, 26, chroma: 1.06),
            ]
            $0.splitShadows = tone(215, 0.03); $0.splitHighlights = tone(60, 0.012)
            $0.colorDensity = 0.5
            $0.skinRefineHueConvergence = 0.5; $0.skinRefineChromaTame = 0.3
            $0.satByLumaHighlights = 0.9
        },
        look("Film", "35mm print emulation in the 2383 spirit: inky (never crushed) toe, creamy shoulder, subtractive density, warm mids, rich reds and olive greens. Weighty and organic.", skinProtection: 0.72) {
            $0.temperature = 0.14
            $0.toneCurve = [(0, 0.01), (0.07, 0.045), (0.3, 0.29), (0.62, 0.69), (0.94, 0.96), (1, 0.99)]
            $0.perChannelMix = 0.7
            $0.hueRegions = [region(25, 22, chroma: 1.08), region(140, 40, shift: -9, chroma: 0.9)]
            $0.colorDensity = 0.6
            $0.satByLumaShadows = 0.88; $0.satByLumaHighlights = 0.85
            $0.splitShadows = tone(250, 0.014); $0.splitHighlights = tone(75, 0.01)
            $0.skinRefineHueConvergence = 0.35; $0.skinRefineChromaTame = 0.2
        },
        look("Golden", "Golden-hour glow: amber light wrapped around everything, honeyed highlights, soft toe. Blues step back so the warmth owns the frame. Flattering and optimistic.", skinProtection: 0.6) {
            $0.temperature = 0.4; $0.tint = 0.06
            $0.toneCurve = [(0, 0.008), (0.11, 0.1), (0.5, 0.535), (0.92, 0.94), (1, 1)]
            $0.perChannelMix = 0.55
            $0.hueRegions = [region(250, 40, chroma: 0.8)]
            $0.vibrance = 0.08; $0.colorDensity = 0.3
            $0.satByLumaShadows = 0.86; $0.satByLumaHighlights = 0.95
            $0.splitShadows = tone(45, 0.018); $0.splitHighlights = tone(80, 0.03)
            $0.skinRefineHueConvergence = 0.4; $0.skinRefineChromaTame = 0.2
        },
        look("Cream", "Soft pastel portrait film: open shadows, creamy evened skin, muted sage greens and powder blues, warm milky highlights. The gentle, expensive wedding-film feel.", skinProtection: 0.7) {
            $0.toneCurve = [(0, 0.02), (0.12, 0.14), (0.5, 0.55), (0.88, 0.92), (1, 0.98)]
            $0.perChannelMix = 0.35
            $0.hueRegions = [region(145, 40, shift: -6, chroma: 0.8), region(250, 40, chroma: 0.85)]
            $0.saturation = 0.9; $0.vibrance = 0.04; $0.colorDensity = 0.15
            $0.satByLumaShadows = 0.85; $0.satByLumaHighlights = 0.9
            $0.splitShadows = tone(40, 0.008); $0.splitHighlights = tone(75, 0.018)
            $0.skinRefineHueConvergence = 0.6; $0.skinRefineChromaTame = 0.45
        },
        look("Terra", "Earthy editorial: terracotta warmth, sage-shifted greens, dusty muted blues, cozy density. The lived-in, organic palette of modern lifestyle film.", skinProtection: 0.7) {
            $0.temperature = 0.15
            $0.toneCurve = [(0, 0.02), (0.1, 0.09), (0.5, 0.52), (0.92, 0.93), (1, 0.985)]
            $0.perChannelMix = 0.45
            $0.hueRegions = [
                region(140, 42, shift: -14, chroma: 0.85),
                region(40, 26, shift: -6, chroma: 1.15),
                region(250, 40, shift: -8, chroma: 0.7, lightness: 0.005),
            ]
            $0.saturation = 0.95; $0.colorDensity = 0.45
            $0.satByLumaShadows = 0.9; $0.satByLumaHighlights = 0.9
            $0.splitShadows = tone(60, 0.014); $0.splitHighlights = tone(70, 0.016)
            $0.skinRefineHueConvergence = 0.45; $0.skinRefineChromaTame = 0.3
        },
        look("Moody", "Dark and atmospheric, the modern way: deep tonality that never crushes, a desaturated cool environment - and skin kept warm and alive in the gloom. Cinematic tension.", skinProtection: 0.85) {
            $0.toneCurve = [(0, 0.008), (0.09, 0.055), (0.5, 0.44), (0.9, 0.9), (1, 0.97)]
            $0.perChannelMix = 0.45
            $0.hueRegions = [region(145, 40, chroma: 0.75), region(250, 45, chroma: 0.85)]
            $0.saturation = 0.85; $0.colorDensity = 0.55
            $0.satByLumaShadows = 0.95; $0.satByLumaHighlights = 0.85
            $0.splitShadows = tone(235, 0.022); $0.splitHighlights = tone(60, 0.008)
            $0.skinRefineHueConvergence = 0.5; $0.skinRefineChromaTame = 0.35
        },
        look("Arctic", "Bright winter daylight: icy blue-leaning light, open crisp tonality, clean highlights. Cold with energy - the fresh alternative to warm looks, never gloomy.", skinProtection: 0.92) {
            $0.temperature = -0.25; $0.tint = 0.03
            $0.toneCurve = [(0, 0.004), (0.1, 0.1), (0.48, 0.54), (0.9, 0.94), (1, 1)]
            $0.perChannelMix = 0.4
            $0.saturation = 0.95; $0.vibrance = 0.05; $0.colorDensity = 0.2
            $0.satByLumaShadows = 0.9; $0.satByLumaHighlights = 0.92
            $0.splitShadows = tone(225, 0.012); $0.splitHighlights = tone(235, 0.014)
            $0.skinRefineHueConvergence = 0.6; $0.skinRefineChromaTame = 0.3
        },
        look("Neon", "Made for rooms with RGB light: saturated lights get louder, denser and slightly deeper, shadows lean electric violet, the frame goes late-night - while your face stays warm and true.", skinProtection: 0.94) {
            $0.toneCurve = [(0, 0.004), (0.1, 0.06), (0.5, 0.47), (0.9, 0.92), (1, 0.99)]
            $0.perChannelMix = 0.4
            $0.hueRegions = [region(320, 40, chroma: 1.15), region(210, 40, shift: 6, chroma: 1.12), region(150, 35, shift: 8, taper: 0.17)]
            $0.chromaPop = 0.3; $0.colorDensity = 0.5; $0.vibrance = 0.05
            $0.satByLumaShadows = 1.05; $0.satByLumaHighlights = 0.9
            $0.splitShadows = tone(270, 0.02); $0.splitHighlights = tone(200, 0.008)
            $0.skinRefineHueConvergence = 0.55; $0.skinRefineChromaTame = 0.45
        },
        look("Punch", "Vivid commercial pop that survives platform compression: confident contrast, loud-but-dense color, disciplined blues. Energy without neon skin.", skinProtection: 0.9) {
            $0.toneCurve = [(0, 0), (0.08, 0.05), (0.47, 0.51), (0.88, 0.94), (1, 1)]
            $0.perChannelMix = 0.5
            $0.vibrance = 0.22; $0.saturation = 1.06; $0.chromaPop = 0.2; $0.colorDensity = 0.45
            $0.hueRegions = [region(255, 40, chroma: 1.08, lightness: -0.01)]
            $0.satByLumaShadows = 0.92; $0.satByLumaHighlights = 0.92
            $0.skinRefineHueConvergence = 0.45; $0.skinRefineChromaTame = 0.4
        },
        look("Fade", "Sun-bleached nostalgia: milky lifted blacks, softened highlights, washed color with warm mids over green-leaning shadows. The found-footage, disposable-camera memory.", skinProtection: 0.5) {
            $0.temperature = 0.15; $0.tint = -0.05
            $0.toneCurve = [(0, 0.07), (0.12, 0.15), (0.5, 0.53), (0.9, 0.89), (1, 0.94)]
            $0.perChannelMix = 0.5
            $0.saturation = 0.84; $0.colorDensity = 0.2
            $0.satByLumaShadows = 0.8
            $0.splitShadows = tone(130, 0.01); $0.splitHighlights = tone(70, 0.014)
            $0.skinRefineHueConvergence = 0.4; $0.skinRefineChromaTame = 0.25
        },
        look("Mono", "Warm classic black & white: orange-filter channel mix for luminous smooth skin, filmic contrast with a soft toe, and a hint of warm paper tone. Timeless.", skinProtection: 0) {
            $0.monochromeWeights = (0.48, 0.42, 0.1)
            $0.monochromeTint = tone(70, 0.012)
            $0.toneCurve = [(0, 0.004), (0.09, 0.065), (0.45, 0.47), (0.9, 0.935), (1, 1)]
        },
    ]
}
