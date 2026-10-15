import AppKit
import SwiftUI

/// Settings window: id "settings", fixed width 840, height follows content, hidden-inset title
/// bar, not resizable/minimizable, Escape closes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let state = SettingsState()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView(state: state))
        hosting.sizingOptions = [.preferredContentSize]
        let window = EscapeClosingWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.Colors.background)
        window.setFrameAutosaveName("settings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: SettingsTab = .general) {
        state.tab = tab
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Closes on Escape.
final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
