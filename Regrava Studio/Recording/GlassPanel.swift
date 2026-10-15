import AppKit
import SwiftUI

/// Window levels: overlays sit at main-menu + 1, the picker and widget at main-menu + 2.
extension NSWindow.Level {
    static let recordingOverlay = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    static let recordingPanel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
}

/// Floating HUD "glass" panel used by the record picker (64 tall, radius 16) and the
/// recording widget (48 tall, radius 11): frameless, always on top, on all Spaces, kept out
/// of recordings, draggable from anywhere, width fitted to content, 100 px above the bottom.
/// This uses the HUD visual-effect material.
@MainActor
final class GlassPanel<Content: View>: NSPanel {
    private let host: NSHostingView<AnyView>
    private let height: CGFloat
    private let positionKey: String
    private let focusable: Bool

    init(height: CGFloat, cornerRadius: CGFloat, focusable: Bool, positionKey: String, @ViewBuilder content: () -> Content) {
        self.height = height
        self.positionKey = positionKey
        self.focusable = focusable
        host = NSHostingView(rootView: AnyView(content().environment(\.colorScheme, .dark)))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
            styleMask: focusable ? [.borderless, .fullSizeContentView] : [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .recordingPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        sharingType = .none
        appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        host.sizingOptions = [.intrinsicContentSize]
    }

    override var canBecomeKey: Bool { focusable }

    /// Fits the width to the content and places the panel (remembered position, else
    /// horizontally centered 100 px above the bottom of the screen with the mouse).
    func present() {
        let width = max(host.fittingSize.width, 200)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        var origin: NSPoint
        if let saved = UserDefaults.standard.string(forKey: "panel.\(positionKey)"),
           NSScreen.screens.contains(where: { $0.frame.contains(NSPointFromString(saved)) }) {
            origin = NSPointFromString(saved)
        } else if let frame = screen?.visibleFrame {
            origin = NSPoint(x: frame.midX - width / 2, y: (screen?.frame.minY ?? 0) + 100)
        } else {
            origin = .zero
        }
        origin.x = origin.x.rounded()
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
    }

    /// Keeps the panel centered on its previous center when the content width changes.
    func refit() {
        let width = max(host.fittingSize.width, 200)
        guard abs(width - frame.width) > 0.5 else { return }
        let center = frame.midX
        setFrame(NSRect(x: (center - width / 2).rounded(), y: frame.minY, width: width, height: height), display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panel.\(positionKey)")
    }
}
