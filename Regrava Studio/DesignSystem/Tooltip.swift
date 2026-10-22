import AppKit
import SwiftUI

// Tooltips: shown 125 ms after the pointer settles on an element, immediately while another
// tooltip was visible less than 400 ms ago, and hidden on pointer down, scroll or blur.
// Placement defaults to top, 8 pt from the element, with an optional shortcut after the label.

enum TooltipPlacement {
    case top, bottom, left, right
}

struct TooltipConfig: Equatable {
    var label: String
    var shortcut: String?
    var placement: TooltipPlacement = .top
    var maxWidth: CGFloat = 300
}

extension View {
    /// Shows `label` (and `shortcut`, e.g. "⌘←") in a floating tooltip. Empty or nil hides it.
    func tooltip(_ label: String?, shortcut: String? = nil, placement: TooltipPlacement = .top, maxWidth: CGFloat = 300) -> some View {
        let text = label ?? ""
        let config = text.isEmpty && shortcut == nil ? nil : TooltipConfig(label: text, shortcut: shortcut, placement: placement, maxWidth: maxWidth)
        return background(TooltipAnchor(config: config))
    }
}

/// Invisible view that tracks the pointer over its element.
private struct TooltipAnchor: NSViewRepresentable {
    var config: TooltipConfig?

    func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView() }

    func updateNSView(_ view: TooltipAnchorView, context: Context) {
        view.config = config
    }

    static func dismantleNSView(_ view: TooltipAnchorView, coordinator: ()) {
        TooltipController.shared.leave(view)
    }
}

final class TooltipAnchorView: NSView {
    var config: TooltipConfig? {
        didSet {
            guard config != oldValue else { return }
            TooltipController.shared.anchorChanged(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { TooltipController.shared.enter(self) }
    override func mouseExited(with event: NSEvent) { TooltipController.shared.leave(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TooltipController.shared.leave(self) }
    }
}

@MainActor
final class TooltipController {
    static let shared = TooltipController()

    private let showDelay: TimeInterval = 0.125
    private let warmWindow: TimeInterval = 0.4

    private weak var hovered: TooltipAnchorView?
    private weak var shown: TooltipAnchorView?
    private var pending: DispatchWorkItem?
    private var lastHiddenAt: Date = .distantPast
    private var panel: NSPanel?
    private var hosting: NSHostingView<TooltipBubble>?
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss() }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func enter(_ anchor: TooltipAnchorView) {
        hovered = anchor
        pending?.cancel()
        let isWarm = shown != nil || Date().timeIntervalSince(lastHiddenAt) < warmWindow
        if isWarm {
            show(anchor)
        } else {
            let work = DispatchWorkItem { [weak self, weak anchor] in
                guard let self, let anchor, self.hovered === anchor else { return }
                self.show(anchor)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
        }
    }

    func leave(_ anchor: TooltipAnchorView) {
        guard hovered === anchor || shown === anchor else { return }
        hovered = nil
        pending?.cancel()
        hide()
    }

    /// Label changes while shown update the bubble.
    func anchorChanged(_ anchor: TooltipAnchorView) {
        guard shown === anchor else { return }
        if anchor.config == nil { hide() } else { show(anchor) }
    }

    /// Pointer down, scroll, key or blur: hide until the pointer enters another element.
    private func dismiss() {
        pending?.cancel()
        hovered = nil
        hide()
    }

    private func hide() {
        guard shown != nil else { return }
        shown = nil
        panel?.orderOut(nil)
        lastHiddenAt = Date()
    }

    private func show(_ anchor: TooltipAnchorView) {
        guard let config = anchor.config, let window = anchor.window, window.isVisible else {
            hide()
            return
        }
        let bubble = TooltipBubble(config: config)
        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = bubble
        } else {
            let hosting = NSHostingView(rootView: bubble)
            panel.contentView = hosting
            self.hosting = hosting
        }
        guard let hosting else { return }
        let size = hosting.fittingSize
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let offset: CGFloat = 8 - TooltipBubble.arrow
        var origin: CGPoint
        switch config.placement {
        case .top: origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + offset)
        case .bottom: origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - offset - size.height)
        case .left: origin = CGPoint(x: rect.minX - offset - size.width, y: rect.midY - size.height / 2)
        case .right: origin = CGPoint(x: rect.maxX + offset, y: rect.midY - size.height / 2)
        }
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        shown = anchor
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        self.panel = panel
        return panel
    }
}

/// Dark rounded label with an arrow toward the element; label 13 pt medium, shortcut in
/// secondary text on a faint chip.
struct TooltipBubble: View {
    static let arrow: CGFloat = 6
    var config: TooltipConfig

    var body: some View {
        let shape = BubbleShape(placement: config.placement, arrow: Self.arrow)
        content
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: config.maxWidth)
            .background(shape.fill(Color(hex: 0x1E1F23)))
            .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 1))
            .padding(edgeInsets)
            .fixedSize()
            .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        HStack(spacing: 9) {
            if !config.label.isEmpty {
                Text(config.label)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            if let shortcut = config.shortcut {
                shortcutChip(shortcut)
            }
        }
    }

    private func shortcutChip(_ shortcut: String) -> some View {
        let spaced = shortcut.map { String($0) }.joined(separator: " ")
        return Text(spaced)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
    }

    /// Room for the arrow on the side facing the element.
    private var edgeInsets: EdgeInsets {
        let a = Self.arrow
        switch config.placement {
        case .top: return EdgeInsets(top: 0, leading: 0, bottom: a, trailing: 0)
        case .bottom: return EdgeInsets(top: a, leading: 0, bottom: 0, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: a)
        case .right: return EdgeInsets(top: 0, leading: a, bottom: 0, trailing: 0)
        }
    }
}

/// Rounded rect (radius 7) whose arrow sits outside it, centred on the facing edge.
private struct BubbleShape: Shape {
    var placement: TooltipPlacement
    var arrow: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: 7)
        let a = arrow
        var tri = Path()
        switch placement {
        case .top:
            tri.move(to: CGPoint(x: rect.midX - a, y: rect.maxY - 1))
            tri.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + a))
            tri.addLine(to: CGPoint(x: rect.midX + a, y: rect.maxY - 1))
        case .bottom:
            tri.move(to: CGPoint(x: rect.midX - a, y: rect.minY + 1))
            tri.addLine(to: CGPoint(x: rect.midX, y: rect.minY - a))
            tri.addLine(to: CGPoint(x: rect.midX + a, y: rect.minY + 1))
        case .left:
            tri.move(to: CGPoint(x: rect.maxX - 1, y: rect.midY - a))
            tri.addLine(to: CGPoint(x: rect.maxX + a, y: rect.midY))
            tri.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY + a))
        case .right:
            tri.move(to: CGPoint(x: rect.minX + 1, y: rect.midY - a))
            tri.addLine(to: CGPoint(x: rect.minX - a, y: rect.midY))
            tri.addLine(to: CGPoint(x: rect.minX + 1, y: rect.midY + a))
        }
        tri.closeSubpath()
        // One outline, so the border doesn't cross the arrow's base.
        return body.union(tri)
    }
}
