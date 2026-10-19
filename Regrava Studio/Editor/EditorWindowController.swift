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
        window.setContentSize(NSSize(width: 1280, height: 740))
        window.minSize = NSSize(width: 1280, height: 740)
        window.setFrameAutosaveName("project")
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

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
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

    /// Unsaved changes with autosave off: "Save and close" / "Cancel" / "Close without saving".
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty, !Preferences.shared.autoSaveProject else { return true }
        let alert = NSAlert()
        alert.messageText = "Your project has unsaved changes. Are you sure you want to close?"
        alert.addButton(withTitle: "Save and close")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close without saving")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.saveNow()
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        if model.isDirty && Preferences.shared.autoSaveProject { model.saveNow() }
        model.tearDown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        AppController.shared.editorClosed(self)
    }

    // MARK: Shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if window.firstResponder is NSTextView { return event }
            if event.type == .flagsChanged {
                // Holding ⌥ activates the split tool temporarily.
                let option = event.modifierFlags.contains(.option)
                if option != self.optionHeld {
                    self.optionHeld = option
                    self.model.isSplitToolActive = option
                }
                return event
            }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let editor = model
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let openZoom = editor.openZoomID

        switch (event.keyCode, flags) {
        case (49, []): editor.togglePlay() // Space
        case (123, []): editor.isPlaying ? editor.step(milliseconds: -1000) : editor.step(frames: -1)
        case (124, []): editor.isPlaying ? editor.step(milliseconds: 500) : editor.step(frames: 1)
        case (123, [.shift]): editor.step(milliseconds: -2000)
        case (124, [.shift]): editor.step(milliseconds: 1000)
        case (123, [.command]): editor.seek(to: 0)
        case (124, [.command]): editor.seek(to: editor.durationMs)
        case (53, []): editor.closeCurrentSidebarPanel() // Esc
        case (36, []), (76, []): // ↩ "Finish editing mask"
            guard editor.openMaskID != nil else { return false }
            editor.sidebarItem = nil
        case (51, []), (117, []): // Delete
            if let mask = editor.openMaskID {
                editor.removeMasks([mask])
                return true
            }
            if let slice = editor.openSliceID {
                editor.removeSlice(slice)
                return true
            }
            let ids = editor.selectedZoomIDs.isEmpty ? Set([openZoom].compactMap { $0 }) : editor.selectedZoomIDs
            guard !ids.isEmpty else { return false }
            editor.removeZooms(ids)
        case (36, [.command, .shift]): // ⌘⇧↩ preview mode
            editor.layoutType = editor.layoutType == .preview ? .edit : .preview
        default:
            switch (key, flags) {
            case ("k", [.command]): editor.isCommandMenuOpen.toggle()
            case ("z", [.command]): editor.undo()
            case ("z", [.command, .shift]): editor.redo()
            case ("=", [.command]), ("+", [.command]): editor.zoomTimeline(in: true)
            case ("-", [.command]): editor.zoomTimeline(in: false)
            case ("d", [.command]):
                guard let openZoom else { return false }
                editor.duplicateZoom(openZoom)
            case ("d", []):
                if let mask = editor.openMaskID {
                    editor.updateMask(mask) { $0.isDisabled.toggle() }
                    return true
                }
                guard let openZoom else { return false }
                editor.updateZoom(openZoom) { $0.isDisabled.toggle() }
            case ("c", []):
                // Zoom variant when a zoom is open or under the playhead, otherwise the clip.
                let source = editor.currentSourceTimeMs
                if let mask = editor.openMaskID {
                    editor.splitMask(mask, at: source)
                } else if let target = openZoom ?? editor.project.zooms.first(where: { $0.contains(source) })?.id {
                    editor.splitZoom(target, at: source)
                } else {
                    editor.splitSlice(atPlayback: editor.currentTimeMs)
                }
            case ("a", []):
                guard let openZoom else { return false }
                editor.updateZoom(openZoom) { $0.mode = .auto }
            case ("m", []):
                guard let openZoom else { return false }
                editor.updateZoom(openZoom) { $0.mode = .manual }
            case ("=", []), ("-", []):
                guard let openZoom else { return false }
                let delta = key == "=" ? 0.2 : -0.2
                editor.updateZoom(openZoom) { $0.scale = clamp(($0.scale + delta) * 10, 10, 40).rounded() / 10 }
            case (let digit, []) where digit.count == 1 && digit.first!.isNumber:
                guard let openZoom, let value = Int(digit) else { return false }
                let level = value == 0 ? (Preferences.shared.defaultZoomLevel ?? 2) : EditorShortcuts.zoomLevels[value - 1]
                editor.updateZoom(openZoom) { $0.scale = level }
            default:
                return false
            }
        }
        return true
    }
}
