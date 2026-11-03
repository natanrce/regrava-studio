@preconcurrency import AVFoundation
import AppKit
import RegravaCore
import SwiftUI

/// One window per project.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private var keyMonitor: Any?
    private var optionHeld = false

    init(bundleURL: URL, project: Project) {
        model = EditorModel(bundleURL: bundleURL, project: project)
        let hosting = NSHostingController(rootView: EditorView(editor: model))
        // Fixed window size; don't let the SwiftUI content resize the window.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.Colors.background)
        window.collectionBehavior.insert(.fullScreenNone)
        // Taller for recordings that can have a device frame.
        let height: CGFloat = model.project.canHaveDeviceFrame ? 780 : 740
        let minimum = NSSize(width: 1280, height: height)
        window.setContentSize(minimum)
        window.contentMinSize = minimum
        window.minSize = minimum
        window.setFrameAutosaveName("project")
        // A saved frame from before the minimum (or from a smaller screen) is restored as is;
        // grow it back so the layout never breaks.
        if window.frame.width < minimum.width || window.frame.height < minimum.height {
            var frame = window.frame
            frame.size = NSSize(width: max(frame.width, minimum.width), height: max(frame.height, minimum.height))
            window.setFrame(frame, display: false)
        }
        window.center()
        super.init(window: window)
        window.delegate = self
        updateTitle()
        installKeyMonitor()
        Task { await model.prepare() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateTitle() {
        window?.title = "Project - \(model.projectName)"
    }

    // MARK: Window

    /// Never smaller than the minimum, even if something resets `minSize`.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, sender.minSize.width), height: max(frameSize.height, sender.minSize.height))
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) {
        positionTrafficLights()
        // The front editor gets the media keys.
        model.registerMediaKeys()
    }
    func windowDidEndLiveResize(_ notification: Notification) { positionTrafficLights() }

    /// Traffic lights at {x: 23, y: 22} in the 60 px topbar (`trafficLightPosition`): the
    /// title bar is stretched to the topbar's height so the buttons share its centre line.
    private func positionTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebarView = close.superview,
              let container = titlebarView.superview else { return }
        let height: CGFloat = 60
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        titlebarView.frame = container.bounds
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 23 + CGFloat(index) * 20, y: height - 22 - button.frame.height))
        }
    }

    /// `closeConfirmation`: a new recording never saved asks to save or delete it; unsaved
    /// changes ask to save or close without saving, whatever autosave does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let isNew = model.isNewRecording && model.project.lastSavedAt == nil
        guard isNew || model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = isNew ? "Do you want to save your project before closing or delete it?" : "Your project has unsaved changes. Are you sure you want to close?"
        alert.addButton(withTitle: "Save and close")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: isNew ? "Delete and close" : "Close without saving")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.saveNow()
            return true
        case .alertThirdButtonReturn:
            if isNew { model.trashProject() } else { model.discardChanges() }
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.writePreviewImage()
        model.tearDown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        AppController.shared.editorClosed(self)
    }

    // MARK: Shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .flagsChanged {
                self.handleAltHold(event)
                return event
            }
            // Holding ⌥ alone turns the split tool on; any other key press or release turns it off.
            if self.optionHeld {
                self.optionHeld = false
                self.model.isSplitToolActive = false
            }
            guard event.type == .keyDown else { return event }
            if window.firstResponder is NSTextView { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handleAltHold(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if optionHeld {
            optionHeld = false
            model.isSplitToolActive = false
        } else if flags == [.option], event.keyCode == 58 || event.keyCode == 61 {
            optionHeld = true
            model.isSplitToolActive = true
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let editor = model
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "k" && flags == [.command] {
            editor.commandMenu.toggle()
            return true
        }
        // The menu's own keys while it is open; action shortcuts are off.
        guard editor.commandMenu.session == nil else { return false }
        if event.keyCode == 53 && flags.isEmpty {
            // Esc: clears the selection and closes the item inspector (or the armed tool).
            editor.clearSelected()
            editor.closeCurrentSidebarPanel()
            return true
        }
        if editor.performShortcut(event) { return true }
        // Registered by the Camera Layout panel while it is shown.
        if key == "h" && flags.isEmpty {
            guard editor.sidebarRoot == .cameraLayout, editor.sidebarItem == nil, editor.layoutType.showsSidebar,
                  editor.project.recording.hasCamera else { return false }
            editor.change { $0.camera.hide.toggle() }
            return true
        }
        return false
    }
}
