import AppKit
import SwiftUI

/// The child-window shell: 960×720 by default (min 720×680), frameless with a hidden-inset
/// title bar, the traffic lights at (23, 22) of a 60 px top bar, sidebar vibrancy, Escape
/// closes and the frame is remembered.
@MainActor
final class ToolWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: ToolWindowController] = [:]
    private let key: String

    /// Brings an already open window forward (`window.focusChildWindow`).
    static func focus(_ key: String) -> Bool {
        guard let existing = open[key] else { return false }
        existing.window?.makeKeyAndOrderFront(nil)
        return true
    }

    static func open(key: String, title: String, autosaveName: String, content: (_ close: @escaping () -> Void) -> AnyView) {
        let controller = ToolWindowController(key: key, title: title, autosaveName: autosaveName)
        let close: () -> Void = { [weak controller] in controller?.window?.performClose(nil) }
        controller.install(content(close))
        open[key] = controller
        controller.window?.center()
        controller.showWindow(nil)
    }

    private init(key: String, title: String, autosaveName: String) {
        self.key = key
        let window = EscapeClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 720, height: 680)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenNone)
        window.setFrameAutosaveName(autosaveName)
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func install(_ view: AnyView) {
        guard let effect = window?.contentView else { return }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    func windowWillClose(_ notification: Notification) { Self.open[key] = nil }
    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }

    private func positionTrafficLights() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let titlebarView = close.superview, let container = titlebarView.superview else { return }
        let height: CGFloat = 60
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        titlebarView.frame = container.bounds
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 23 + CGFloat(index) * 20, y: height - 22 - button.frame.height))
        }
    }
}
