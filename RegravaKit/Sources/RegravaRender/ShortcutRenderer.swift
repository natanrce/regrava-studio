import AppKit
import CoreImage
import CoreText
import Foundation
import RegravaCore

/// Draws the keyboard shortcuts overlay: every key is its own dark rounded card with a soft
/// shadow, drawn above the captions.
final class ShortcutRenderer: @unchecked Sendable {
    let track: ShortcutTrack
    private let canvasHeight: Double
    /// Stage units (1080 high) to canvas pixels.
    private let unit: Double
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    init?(project: Project, canvas: Rect2, captionsShown: Bool, fps: Double) {
        guard let track = ShortcutTrack(project: project, canvas: canvas, captionsShown: captionsShown, fps: fps) else { return nil }
        self.track = track
        canvasHeight = canvas.height
        unit = canvas.height / 1080
    }

    private func ciRect(_ r: Rect2) -> CGRect { CGRect(x: r.x, y: canvasHeight - r.y - r.height, width: r.width, height: r.height) }

    // MARK: Artwork (256-unit key space)

    private static let keySpace = 256.0
    private static let bodyHeight = 250.0
    private static let padding = 31.25

    private struct TextStyle {
        var size: Double
        var weight: NSFont.Weight
        var font: CTFont { NSFont.systemFont(ofSize: size, weight: weight) }
    }

    /// 33 and 0.225 of the body height.
    private static let labelStyle = TextStyle(size: bodyHeight * 0.33, weight: .regular)
    private static let symbolStyle = TextStyle(size: bodyHeight * 0.33, weight: .regular)
    private static let smallLabelStyle = TextStyle(size: bodyHeight * 0.225, weight: .medium)

    /// The stage text box: ceil(width) × ceil(1.2·size).
    private static func measure(_ text: String, _ style: TextStyle) -> (line: CTLine, width: Double, height: Double) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: CGColor(gray: 1, alpha: 1)]))
        return (line, ceil(CTLineGetTypographicBounds(line, nil, nil, nil)), ceil(style.size * 1.2))
    }

    /// Draws text whose box top-left is `(x, y)` in top-down key space, scaled by `scale`.
    private static func draw(_ text: String, _ style: TextStyle, x: Double, y: Double, scale: Double, in context: CGContext) {
        let m = measure(text, style)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(m.line, &ascent, &descent, nil)
        context.saveGState()
        context.translateBy(x: x, y: keySpace - y)
        context.scaleBy(x: scale, y: scale)
        let emTop = (style.size * 1.2 - style.size) / 2
        context.textPosition = CGPoint(x: 0, y: -(emTop + ascent + (style.size - ascent - descent) / 2))
        CTLineDraw(m.line, context)
        context.restoreGState()
    }

    private static func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
        func color(_ hex: UInt32) -> CGColor {
            CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
        }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    }

    /// The key cap at `height` canvas pixels.
    private func artwork(_ cap: ShortcutKeyCap, height: Double) -> CIImage {
        let key = "\(cap.identity)|\(cap.widthRatio)|\((height * 2).rounded())"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let s = Self.keySpace
        let width = s * cap.widthRatio
        let k = height / s
        let supersample = 2.0
        let pw = Int(ceil(width * k * supersample)), ph = Int(ceil(height * supersample))
        guard pw > 0, ph > 0, let context = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        context.scaleBy(x: k * supersample, y: k * supersample)

        // Border 0,0,256r,256 rx 32 (#656565 → #191919); body inset 3, rx 29 (#2b2b2b → #191919).
        context.saveGState()
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: s), cornerWidth: 32, cornerHeight: 32, transform: nil))
        context.clip()
        context.drawLinearGradient(Self.gradient(0x656565, 0x191919), start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        context.restoreGState()
        context.saveGState()
        context.addPath(CGPath(roundedRect: CGRect(x: 3, y: 3, width: width - 6, height: Self.bodyHeight), cornerWidth: 29, cornerHeight: 29, transform: nil))
        context.clip()
        context.drawLinearGradient(Self.gradient(0x2B2B2B, 0x191919), start: CGPoint(x: 0, y: s - 3), end: CGPoint(x: 0, y: 3), options: [])
        context.restoreGState()

        // Text inside the body {3, 3, 256r − 6, 250} (top-down).
        let body = (x: 3.0, y: 3.0, w: width - 6, h: Self.bodyHeight)
        let maxW = body.w - 2 * Self.padding
        switch cap.placement {
        case .center:
            let m = Self.measure(cap.label, Self.labelStyle)
            let scale = min(1, maxW / max(m.width, 1))
            Self.draw(cap.label, Self.labelStyle, x: body.x + body.w / 2 - m.width * scale / 2, y: body.y + body.h / 2 - m.height * scale / 2, scale: scale, in: context)
        case .bottomLeft, .bottomCenter:
            let centred = cap.placement == .bottomCenter
            if let symbol = cap.symbol {
                let m = Self.measure(symbol, Self.symbolStyle)
                Self.draw(symbol, Self.symbolStyle, x: centred ? body.x + body.w / 2 - m.width / 2 : body.x + Self.padding, y: body.y + Self.padding, scale: 1, in: context)
            }
            if !cap.label.isEmpty {
                let m = Self.measure(cap.label, Self.smallLabelStyle)
                let scale = min(1, maxW / max(m.width, 1))
                Self.draw(cap.label, Self.smallLabelStyle, x: centred ? body.x + body.w / 2 - m.width * scale / 2 : body.x + Self.padding, y: body.y + body.h - Self.padding - m.height * scale, scale: scale, in: context)
            }
        }
        let image = context.makeImage().map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(scaleX: 1 / supersample, y: 1 / supersample)) } ?? CIImage.empty()
        cache[key] = image
        return image
    }

    // MARK: Drawing

    private func faded(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        var out = image
        // `fadeOutBlurRadius` 5: blurred by 5·(1 − opacity) stage px while fading.
        let blur = 5 * (1 - opacity) * unit
        if blur > 0.1 { out = out.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: image.extent.insetBy(dx: -3 * blur, dy: -3 * blur)) }
        let a = CGFloat(opacity)
        return out.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
    }

    /// One key: shadow, then the artwork clipped to the sprung rect, faded by its opacity.
    private func key(_ node: ShortcutKeyNode, rect r: Rect2) -> CIImage {
        let ratio = track.sizeRatio
        let radius = ratio * 128 * unit
        let rect = ciRect(r)
        // Black at 0.33, blur ratio·200, offset (0, ratio·25) below the key, Classic.
        let shadow = SmoothShapes.shadow(rect, radius: radius, .init(alpha: 0.33, blur: ratio * 200 * unit, offset: CGVector(dx: 0, dy: -ratio * 25 * unit), directional: nil, unit: unit))
        // Artwork at its resting scale, placed at the sprung rect and clipped to it with
        // smooth corners (`borderRoundness` 1).
        let art = artwork(node.cap, height: node.restingHeight)
        let placed = art.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.maxY - art.extent.height))
        let clipped = SmoothShapes.clip(placed, to: rect, radius: radius)
        return faded(clipped.composited(over: shadow), opacity: node.opacity)
    }

    /// The overlay over `output` at a playback time. With motion blur on, a moving key trails
    /// from `lerp(now, before, strength)` to now like every sprung node (uniform weights,
    /// `smoothFalloffRatio` 0).
    func draw(over output: CIImage, atPlayback time: Double, motionBlurStrength strength: Double = 0, quality: RenderQuality = .export) -> CIImage {
        let nodes = track.scene(atPlayback: time)
        guard !nodes.isEmpty else { return output }
        var before: [Int: ShortcutKeyNode] = [:]
        if strength > 0 {
            for node in track.scene(atPlayback: max(0, time - 1000 / track.fps)) { before[node.instance] = node }
        }
        var result = output
        for node in nodes {
            var image = key(node, rect: node.rect)
            if let previous = before[node.instance] {
                let trailStart = node.rect.lerp(to: previous.rect, strength)
                let travel = node.rect.cornerTravel(to: trailStart)
                if travel >= 1 {
                    let reach = track.sizeRatio * 250 * unit + 8
                    let bounds = ciRect(node.rect).union(ciRect(trailStart)).insetBy(dx: -reach, dy: -reach).integral
                    if let blurred = MotionBlur.accumulate(samples: MotionBlur.sampleCount(travel: travel, quality: quality), bounds: bounds, layer: { t in
                        self.key(node, rect: trailStart.lerp(to: node.rect, t))
                    }) {
                        image = blurred
                    }
                }
            }
            result = image.composited(over: result)
        }
        return result
    }
}
