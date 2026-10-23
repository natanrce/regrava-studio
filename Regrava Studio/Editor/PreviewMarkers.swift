import AppKit
import RegravaCore
import SwiftUI

/// Clickable areas over the preview: the background, the recording and the cursor. Hovering
/// lights the area with a sheen that follows the pointer and a rim; clicking opens its
/// settings with a short toast.
struct PreviewMarkers: View {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    var scale: CGFloat

    var body: some View {
        if !editor.isPlaying && !editor.isAddZoomToolArmed && !editor.isAddMaskToolArmed && editor.openMaskID == nil {
            GeometryReader { geometry in
                let area = editor.recordingAreaRect
                ZStack(alignment: .topLeading) {
                    MarkerArea(rect: CGRect(origin: .zero, size: geometry.size), cornerRadius: 4) {
                        open(.background, "Opened background settings")
                    }
                    MarkerArea(
                        rect: CGRect(x: area.x * scale, y: area.y * scale, width: area.width * scale, height: area.height * scale),
                        cornerRadius: editor.recordingAreaCornerRadius * scale
                    ) {
                        if editor.project.isUsingDeviceFrame {
                            open(.deviceFrame, "Opened device frame settings")
                        } else {
                            open(.background, "Opened background settings")
                        }
                    }
                    // The webcam: opens Camera Layout, or Camera Style when Camera Layout is already open.
                    if let camera = editor.cameraAreaRect {
                        MarkerArea(rect: CGRect(x: camera.rect.x * scale, y: camera.rect.y * scale, width: camera.rect.width * scale, height: camera.rect.height * scale), cornerRadius: camera.cornerRadius * scale) {
                            if editor.sidebarRoot == .cameraLayout {
                                open(.cameraStyle, "Opened camera style settings")
                            } else {
                                open(.cameraLayout, "Opened camera layout settings")
                            }
                        }
                    }
                    if let lens = editor.loupeAreaRect {
                        MarkerArea(rect: CGRect(x: lens.x * scale, y: lens.y * scale, width: lens.width * scale, height: lens.height * scale), cornerRadius: lens.width * scale / 2) {
                            editor.openLoupeAtPlayhead()
                        }
                    }
                    // The shortcut keys.
                    if let keys = editor.shortcutsAreaRect {
                        MarkerArea(rect: CGRect(x: keys.x * scale, y: keys.y * scale, width: keys.width * scale, height: keys.height * scale), cornerRadius: editor.shortcutsCornerRadius * scale) {
                            open(.shortcuts, "Opened keyboard shortcuts settings")
                        }
                    }
                    if let cursor = editor.cursorAreaRect {
                        MarkerArea(rect: CGRect(x: cursor.x * scale, y: cursor.y * scale, width: cursor.width * scale, height: cursor.height * scale), cornerRadius: 4) {
                            open(.cursor, "Opened cursor settings")
                        }
                    }
                }
            }
        }
    }

    private func open(_ root: SidebarRoot, _ message: String) {
        editor.openSidebar(root)
        editor.showToast(message, durationMs: 1000)
    }
}

/// One marker.
struct MarkerArea: View {
    var rect: CGRect
    var cornerRadius: CGFloat
    var action: () -> Void
    @State private var pointer: CGPoint?

    /// Pointer-follow ratio, sheen radius ratio.
    private static let follow = 0.6
    private static let sheenRatio = 1.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            shape.fill(pointer == nil ? Color.clear : Theme.Colors.hover)
            if let pointer {
                let center = CGPoint(x: rect.width / 2, y: rect.height / 2)
                let highlight = CGPoint(
                    x: center.x + (pointer.x - center.x) * Self.follow,
                    y: center.y + (pointer.y - center.y) * Self.follow
                )
                let tilt = min(1, hypot(pointer.x / max(rect.width, 1) * 2 - 1, pointer.y / max(rect.height, 1) * 2 - 1))
                let radius = (rect.width / 2 + rect.height / 2) * Self.sheenRatio
                // ::before — dithered sheen.
                shape
                    .fill(RadialGradient(
                        stops: [.init(color: .white.opacity(0.115), location: 0), .init(color: .clear, location: 0.62)],
                        center: UnitPoint(x: highlight.x / max(rect.width, 1), y: highlight.y / max(rect.height, 1)),
                        startRadius: 0,
                        endRadius: radius
                    ))
                    .mask(Rectangle().fill(ImagePaint(image: Image(nsImage: BayerPattern.image))))
                    .opacity(1 - tilt * 0.35)
                // ::after — 1 px rim.
                shape
                    .strokeBorder(
                        RadialGradient(
                            stops: [.init(color: .white.opacity(0.5), location: 0), .init(color: .clear, location: 0.75)],
                            center: UnitPoint(x: highlight.x / max(rect.width, 1), y: highlight.y / max(rect.height, 1)),
                            startRadius: 0,
                            endRadius: radius * 0.9
                        ),
                        lineWidth: 1
                    )
                    .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .opacity(0.35 + tilt * 0.65)
            }
        }
        .animation(.easeOut(duration: 0.2), value: pointer == nil)
        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
        .contentShape(shape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
        .onTapGesture(perform: action)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// 8×8 ordered-dither tile: opacity 1 − bayer(x, y) × 0.33.
enum BayerPattern {
    static func value(_ x: Int, _ y: Int) -> Double {
        let x0 = x % 2, y0 = y % 2, x1 = (x / 2) % 2, y1 = (y / 2) % 2, x2 = (x / 4) % 2, y2 = (y / 4) % 2
        let v = (((x0 + y0) % 2) * 2 + y0) * 16 + (((x1 + y1) % 2) * 2 + y1) * 4 + (((x2 + y2) % 2) * 2 + y2)
        return Double(v) / 64
    }

    static let image: NSImage = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        for y in 0..<8 {
            for x in 0..<8 {
                rep.setColor(NSColor(white: 1, alpha: 1 - value(x, y) * 0.33), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(rep)
        return image
    }()
}
