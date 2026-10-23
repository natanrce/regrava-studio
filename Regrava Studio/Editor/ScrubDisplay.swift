import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// The layer showing hover-scrub frames over the player. Frames go straight to the layer, never
/// through SwiftUI, so following the pointer redraws nothing else.
@MainActor
final class ScrubDisplay {
    let layer = CALayer()
    private var isActive = false
    /// The last frames stay referenced so the pool does not refill a surface on screen.
    private var held: [CVPixelBuffer] = []

    init() {
        layer.contentsGravity = .resizeAspect
        layer.isHidden = true
        layer.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    func activate() { isActive = true }

    func show(_ buffer: CVPixelBuffer) {
        guard isActive, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        layer.isHidden = false
        CATransaction.commit()
        held.append(buffer)
        if held.count > 3 { held.removeFirst() }
    }

    func hide() {
        isActive = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        layer.contents = nil
        CATransaction.commit()
        held.removeAll()
    }
}

struct ScrubSurface: NSViewRepresentable {
    let display: ScrubDisplay

    final class HostView: NSView {
        var display: ScrubDisplay?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display?.layer.frame = bounds
            CATransaction.commit()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.display = display
        view.layer?.addSublayer(display.layer)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {}
}
