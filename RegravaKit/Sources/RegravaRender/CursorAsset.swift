import AppKit
import CoreImage
import RegravaCore

/// A cursor bitmap with its size and hotspot in points (top-left origin).
public struct CursorAsset: @unchecked Sendable {
    public let image: CIImage
    public let sizePoints: Size2
    public let hotspotPoints: Vec2

    public init(image: CIImage, sizePoints: Size2, hotspotPoints: Vec2) {
        self.image = image
        self.sizePoints = sizePoints
        self.hotspotPoints = hotspotPoints
    }

    /// System arrow when available (needs a running NSApplication), otherwise a vector arrow.
    public static func defaultArrow() -> CursorAsset {
        systemArrow() ?? vectorArrow()
    }

    /// A classic arrow drawn from a path (black fill, white outline), 6× resolution.
    public static func vectorArrow(rasterScale: Double = 6) -> CursorAsset {
        let outline = 1.5
        // Arrow in points, tip at (0, 0), top-left origin.
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 4, y: 12.6),
            CGPoint(x: 6.7, y: 19), CGPoint(x: 9.3, y: 17.9), CGPoint(x: 6.7, y: 11.8),
            CGPoint(x: 12, y: 11.8),
        ]
        let sizePoints = Size2(width: 12 + outline * 2, height: 19 + outline * 2)
        let width = Int(sizePoints.width * rasterScale)
        let height = Int(sizePoints.height * rasterScale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Flip to top-left origin and scale to points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: rasterScale, y: -rasterScale)
        context.translateBy(x: outline, y: outline)
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        context.setLineJoin(.round)
        context.setLineWidth(outline * 2)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(path)
        context.strokePath()
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.addPath(path)
        context.fillPath()
        return CursorAsset(
            image: CIImage(cgImage: context.makeImage()!),
            sizePoints: sizePoints,
            hotspotPoints: Vec2(outline, outline)
        )
    }

    /// The system arrow, rasterized at high resolution so it stays sharp when zoomed.
    /// Returns nil when AppKit cannot provide it (e.g. outside a running application).
    public static func systemArrow(rasterScale: Double = 6) -> CursorAsset? {
        let cursor = NSCursor.arrow
        let source = cursor.image
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }
        let pixelsWide = Int(size.width * rasterScale)
        let pixelsHigh = Int(size.height * rasterScale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        guard let cgImage = rep.cgImage else { return nil }
        return CursorAsset(
            image: CIImage(cgImage: cgImage),
            sizePoints: Size2(width: size.width, height: size.height),
            hotspotPoints: Vec2(cursor.hotSpot.x, cursor.hotSpot.y)
        )
    }
}
