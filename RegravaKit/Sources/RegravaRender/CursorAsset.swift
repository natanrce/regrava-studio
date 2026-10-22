import AppKit
import CoreImage
import RegravaCore

/// A cursor image with its hotspot and the box of its visible (non-shadow) part, both in 0…1 of
/// the full image, top-left origin (`imageInfo`).
public struct CursorAsset: @unchecked Sendable {
    public let image: CIImage
    public let hotspot01: Vec2
    public let visibleRect01: Rect2

    public init(image: CIImage, hotspot01: Vec2, visibleRect01: Rect2) {
        self.image = image
        self.hotspot01 = hotspot01
        self.visibleRect01 = visibleRect01
    }

    /// Measures the visible box.
    public init(cgImage: CGImage, hotspot01: Vec2) {
        self.init(image: CIImage(cgImage: cgImage), hotspot01: hotspot01,
                  visibleRect01: CursorRaster.visibleRect01(cgImage) ?? Rect2(x: 0, y: 0, width: 1, height: 1))
    }

    public var aspectRatio: Double { image.extent.width / max(image.extent.height, 1) }

    /// Where the full image goes (top-left origin) so that its visible part is `visibleHeight`
    /// tall and its hotspot sits on `tip`.
    public func rect(tip: Vec2, visibleHeight: Double) -> Rect2 {
        let height = visibleHeight / max(visibleRect01.height, 0.0001)
        let width = height * aspectRatio
        return Rect2(x: tip.x - hotspot01.x * width, y: tip.y - hotspot01.y * height, width: width, height: height)
    }

    /// The default set's pointer, or a drawn arrow when the bundle has none.
    public static func defaultArrow() -> CursorAsset {
        CursorSets.set(id: CursorSetChoice.defaultID)
            .flatMap { $0.entry(forType: "pointer", variants: [:]) }
            .flatMap { entry in CursorRaster.image(entry.url).map { CursorAsset(cgImage: $0, hotspot01: entry.hotspot01) } }
            ?? vectorArrow()
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
        return CursorAsset(cgImage: context.makeImage()!, hotspot01: Vec2(outline / sizePoints.width, outline / sizePoints.height))
    }

}

/// Every cursor image a project can show, by image name ("pointer", "pointinghand",
/// "ibeamstroke"… and "custom-N" recorded images).
public struct CursorLibrary: @unchecked Sendable {
    public let assets: [String: CursorAsset]
    public let pointer: CursorAsset

    public init(assets: [String: CursorAsset], pointer: CursorAsset) {
        self.assets = assets
        self.pointer = pointer
    }

    /// Only the default arrow.
    public static func arrowOnly() -> CursorLibrary {
        CursorLibrary(assets: [:], pointer: CursorAsset.defaultArrow())
    }

    /// The images a project's recording uses: every standard cursor from the chosen style (its
    /// chosen variants, falling back to the pointer), and the saved images of app cursors
    /// (`bundle/cursors/<id>.png`) only with the classic "macos" style.
    public static func make(project: Project, bundle: URL?) -> CursorLibrary {
        let choice = project.cursor.set
        guard let set = CursorSets.set(id: choice.id) else { return arrowOnly() }
        func bundled(_ type: String) -> CursorAsset? {
            guard let entry = set.entry(forType: type, variants: choice.variants), let image = CursorRaster.image(entry.url) else { return nil }
            return CursorAsset(cgImage: image, hotspot01: entry.hotspot01)
        }
        let pointer = bundled(CursorTypes.defaultName) ?? CursorAsset.vectorArrow()
        var assets: [String: CursorAsset] = [CursorTypes.defaultName: pointer]
        var names = Set(project.mouseEvents.map { CursorTypes.assetName(for: $0.cursorID) })
        names.insert("pointinghand")
        for name in names where assets[name] == nil {
            if CursorTypes.isCustom(name) {
                guard choice.id == "macos", let bundle, let info = project.recording.cursors.first(where: { $0.id == name }),
                      let image = NSImage(contentsOf: ProjectStore.cursorImageURL(bundle: bundle, id: name)),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      info.standardSize.width > 0, info.standardSize.height > 0 else { continue }
                assets[name] = CursorAsset(cgImage: cg, hotspot01: Vec2(info.hotSpot.x / info.standardSize.width, info.hotSpot.y / info.standardSize.height))
            } else if let asset = bundled(name) {
                assets[name] = asset
            }
        }
        return CursorLibrary(assets: assets, pointer: pointer)
    }

    /// The type, else the pointer, else the pointing hand.
    public func asset(named name: String) -> CursorAsset {
        assets[name] ?? assets[CursorTypes.defaultName] ?? assets["pointinghand"] ?? pointer
    }
}
