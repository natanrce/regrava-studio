import AppKit
import CoreImage
import CoreText
import Foundation
import RegravaCore

/// Draws captions with Core Text: words at `fontSize`, the box with a 12-unit radius and a
/// 10-unit outline at 10%, blurred while fading.
final class CaptionRenderer: @unchecked Sendable {
    let track: CaptionTrack
    private let font: CTFont
    private let fontSize: Double
    private let color: CGColor
    private let background: CIColor
    private let outline: CIColor
    private let unit: Double
    private let canvasHeight: Double
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()
    static let padding = 2.0

    /// Sans-serif is the system font (SF Pro); serif and mono are the bundled Instrument Serif
    /// and Geist Mono (SIL Open Font License, see Resources/Fonts).
    static func font(_ style: CaptionsConfig.Font, size: Double) -> CTFont {
        let base = NSFont.systemFont(ofSize: size)
        switch style {
        case .sansSerif: return base
        case .serif: return bundledFont("InstrumentSerif-Regular", size: size) ?? NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) ?? base
        case .mono: return bundledFont("GeistMono-Variable", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private static let descriptors: [String: CTFontDescriptor] = {
        var out: [String: CTFontDescriptor] = [:]
        for name in ["InstrumentSerif-Regular", "GeistMono-Variable"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                  let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = list.first else { continue }
            out[name] = first
        }
        return out
    }()

    static func bundledFont(_ name: String, size: Double) -> CTFont? {
        descriptors[name].map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    /// The text box: measured width + 2·padding, line height 1.2 + 2·padding.
    static func measure(_ text: String, font: CTFont, fontSize: Double) -> Size2 {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return Size2(width: ceil(width) + 2 * padding, height: ceil(fontSize * 1.2) + 2 * padding)
    }

    init?(project: Project, words: [TranscriptWord], canvas: Rect2) {
        let config = project.captions
        guard config.enableTranscript else { return nil }
        let visible = CaptionWords.visible(words, resolver: project.resolver, showSoundLabels: config.showSoundLabels)
        guard !visible.isEmpty else { return nil }
        fontSize = canvas.shortestSide * config.sizeRatio
        font = Self.font(config.font, size: fontSize)
        let f = font, size = fontSize
        let lines = CaptionLayout.lines(visible, maxWidth: canvas.width * 0.8) { Self.measure($0, font: f, fontSize: size) }
        guard !lines.isEmpty else { return nil }
        track = CaptionTrack(lines: lines, config: config, stage: canvas, resolver: project.resolver, fps: Double(project.recording.fps))
        let text = RGBA(hexString: config.color) ?? RGBA(1, 1, 1)
        color = CGColor(srgbRed: text.r, green: text.g, blue: text.b, alpha: 1)
        let bg = RGBA(hexString: config.backgroundColor) ?? RGBA(0, 0, 0)
        background = CIColor(red: bg.r, green: bg.g, blue: bg.b)
        outline = CIColor(red: 1 - bg.r, green: 1 - bg.g, blue: 1 - bg.b, alpha: 0.1)
        unit = canvas.height / 1080
        canvasHeight = canvas.height
    }

    private func ciRect(_ r: Rect2) -> CGRect { CGRect(x: r.x, y: canvasHeight - r.y - r.height, width: r.width, height: r.height) }

    /// The word's text box, drawn at the top baseline.
    private func image(for text: String) -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let size = Self.measure(text, font: font, fontSize: fontSize)
        let scale = 2.0
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard let context = CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        context.scaleBy(x: scale, y: scale)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        // Top of the em box at padding + (lineHeight − fontSize)/2.
        let top = Self.padding + (fontSize * 1.2 - fontSize) / 2
        context.textPosition = CGPoint(x: Self.padding, y: size.height - top - ascent - (fontSize - ascent - descent) / 2)
        CTLineDraw(line, context)
        let result = context.makeImage().map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)) } ?? CIImage.empty()
        cache[text] = result
        return result
    }

    private func faded(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        var out = image
        let blur = 10 * (1 - opacity) * unit
        if blur > 0.1 { out = out.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: image.extent.insetBy(dx: -3 * blur, dy: -3 * blur)) }
        return out.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        ])
    }

    /// Captions over `output` at a playback time.
    func draw(over output: CIImage, atPlayback time: Double) -> CIImage {
        let scene = track.scene(atPlayback: time)
        var result = output
        if let box = scene.box, box.opacity > 0.001 {
            let rect = ciRect(box.rect)
            let ring = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect.insetBy(dx: -10 * unit, dy: -10 * unit)),
                "inputRadius": 22 * unit,
                "inputColor": outline,
            ])?.outputImage ?? CIImage.empty()
            let fill = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect),
                "inputRadius": 12 * unit,
                "inputColor": background,
            ])?.outputImage ?? CIImage.empty()
            result = faded(fill.composited(over: ring), opacity: box.opacity).composited(over: result)
        }
        for word in scene.words where word.opacity > 0.001 {
            let rect = ciRect(word.rect)
            let glyphs = image(for: word.text).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            result = faded(glyphs, opacity: word.opacity).composited(over: result)
        }
        return result
    }
}
