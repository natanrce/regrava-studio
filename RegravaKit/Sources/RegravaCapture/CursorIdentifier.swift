import AppKit
import RegravaCore

/// A cursor image that is not one of the standard system cursors, saved with the recording.
public struct CapturedCursorImage: Sendable {
    public var id: String
    public var pngData: Data
    /// Hotspot and size in points (top-left origin).
    public var hotSpot: Vec2
    public var size: Size2
}

/// Names the cursor currently shown by the system, using the same ids as the recordings
/// (`cursorId`: "arrow", "iBeam", "pointingHand"…). Cursors that are not standard become
/// "custom-N" and their image is kept.
@MainActor
final class CursorIdentifier {
    private struct Fingerprint {
        var pixels: [UInt8]
        var size: CGSize
        var hotSpot: CGPoint

        func matches(_ other: Fingerprint) -> Bool {
            guard abs(size.width - other.size.width) < 0.5, abs(size.height - other.size.height) < 0.5,
                  abs(hotSpot.x - other.hotSpot.x) < 0.5, abs(hotSpot.y - other.hotSpot.y) < 0.5 else { return false }
            var difference = 0
            for i in 0..<pixels.count { difference += abs(Int(pixels[i]) - Int(other.pixels[i])) }
            // Same artwork rasterized from different representations differs only slightly.
            return Double(difference) / Double(pixels.count) < 6
        }
    }

    private static let side = 24
    private lazy var standard: [(id: String, fingerprint: Fingerprint)] = Self.standardCursors().compactMap { id, cursor in
        Self.fingerprint(cursor).map { (id, $0) }
    }
    private var custom: [(id: String, fingerprint: Fingerprint)] = []
    private(set) var customImages: [CapturedCursorImage] = []
    private var last: (fingerprint: Fingerprint, id: String)?

    func reset() {
        custom.removeAll()
        customImages.removeAll()
        last = nil
    }

    /// Id of the cursor on screen now, or nil when the system does not report one.
    func currentID() -> String? {
        guard let cursor = NSCursor.currentSystem, let print = Self.fingerprint(cursor) else { return last?.id }
        if let last, last.fingerprint.matches(print) { return last.id }
        let id = identify(cursor, print)
        last = (print, id)
        return id
    }

    private func identify(_ cursor: NSCursor, _ print: Fingerprint) -> String {
        if let match = standard.first(where: { $0.fingerprint.matches(print) }) { return match.id }
        if let match = custom.first(where: { $0.fingerprint.matches(print) }) { return match.id }
        let id = "custom-\(custom.count + 1)"
        custom.append((id, print))
        if let png = Self.pngData(cursor.image) {
            customImages.append(CapturedCursorImage(
                id: id,
                pngData: png,
                hotSpot: Vec2(cursor.hotSpot.x, cursor.hotSpot.y),
                size: Size2(width: cursor.image.size.width, height: cursor.image.size.height)
            ))
        }
        return id
    }

    private static func fingerprint(_ cursor: NSCursor) -> Fingerprint? {
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        let pixels = Array(UnsafeBufferPointer(start: data, count: side * side * 4))
        return Fingerprint(pixels: pixels, size: image.size, hotSpot: cursor.hotSpot)
    }

    private static func pngData(_ image: NSImage) -> Data? {
        let scale = 2.0
        let size = image.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Standard AppKit cursors under their recorded names.
    static func standardCursors() -> [(String, NSCursor)] {
        var cursors: [(String, NSCursor)] = [
            ("arrow", .arrow),
            ("iBeam", .iBeam),
            ("crosshair", .crosshair),
            ("closedHand", .closedHand),
            ("openHand", .openHand),
            ("pointingHand", .pointingHand),
            ("resizeLeft", .resizeLeft),
            ("resizeRight", .resizeRight),
            ("resizeLeftRight", .resizeLeftRight),
            ("resizeUp", .resizeUp),
            ("resizeDown", .resizeDown),
            ("resizeUpDown", .resizeUpDown),
            ("disappearingItem", .disappearingItem),
            ("iBeamCursorForVerticalLayout", .iBeamCursorForVerticalLayout),
            ("operationNotAllowed", .operationNotAllowed),
            ("dragLink", .dragLink),
            ("dragCopy", .dragCopy),
            ("contextualMenu", .contextualMenu),
        ]
        if #available(macOS 15.0, *) {
            cursors += [("zoomIn", .zoomIn), ("zoomOut", .zoomOut)]
            let edges: [(String, NSCursor.FrameResizePosition)] = [
                ("North", .top), ("South", .bottom), ("West", .left), ("East", .right),
                ("NorthWest", .topLeft), ("NorthEast", .topRight), ("SouthWest", .bottomLeft), ("SouthEast", .bottomRight),
            ]
            for (name, position) in edges {
                cursors.append(("windowResize\(name)", .frameResize(position: position, directions: .outward)))
            }
            cursors += [
                ("windowResizeNorthSouth", .frameResize(position: .top, directions: .all)),
                ("windowResizeEastWest", .frameResize(position: .left, directions: .all)),
                ("windowResizeNorthWestSouthEast", .frameResize(position: .topLeft, directions: .all)),
                ("windowResizeNorthEastSouthWest", .frameResize(position: .topRight, directions: .all)),
            ]
        }
        return cursors
    }
}
