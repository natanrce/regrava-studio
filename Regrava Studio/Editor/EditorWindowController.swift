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
            if let layout = editor.openLayoutID {
                editor.removeLayouts([layout])
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
            case (let digit, [.command]) where digit.count == 1 && "1234567890".contains(digit):
                // Sidebar panels ⌘1…⌘0, when enabled.
                guard let entry = editor.railEntries.first(where: { String($0.key.character) == digit }), entry.disabledTooltip == nil else { return false }
                editor.openSidebar(entry.root)
            case ("h", []):
                // Registered by the Camera Layout panel while it is shown.
                guard editor.sidebarRoot == .cameraLayout, editor.sidebarItem == nil, editor.layoutType.showsSidebar,
                      editor.project.recording.hasCamera else { return false }
                editor.change { $0.camera.hide.toggle() }
            case ("l", [.control]): editor.toggleAddLayoutTool()
            case ("l", []):
                // "Toggle zoom loupe mode" on a zoom, else "Play or increase speed".
                let source = editor.currentSourceTimeMs
                if let target = openZoom ?? editor.project.zooms.first(where: { $0.contains(source) })?.id {
                    editor.updateZoom(target) { $0.presentation = $0.presentation == .loupe ? .screen : .loupe }
                } else {
                    editor.playToward(1)
                }
            case ("j", []): editor.playToward(-1) // "Play backward or increase speed"
            case ("x", []): return editor.rippleRemoveSlice() // "Remove slice till previous cut"
            case ("s", []): return editor.openSliceSpeedList() // "Set slice speed"
            case ("v", []): return editor.openSliceVolumeList(systemAudio: false) // "Set slice volume"
            case ("v", [.control]): return editor.openSliceVolumeList(systemAudio: true)
            case ("k", []): editor.togglePlay() // "Pause" / "Play", resets the speed
            case ("1", []) where editor.openLayoutID != nil, ("2", []) where editor.openLayoutID != nil,
                 ("3", []) where editor.openLayoutID != nil, ("4", []) where editor.openLayoutID != nil:
                // Layout mode: Overlay / Fullscreen / Hide camera / Cutout.
                let types: [String: CameraLayoutType] = ["1": .cameraOverlay, "2": .fullscreenCamera, "3": .screenOnly, "4": .cutoutCamera]
                guard let layout = editor.openLayoutID, let type = types[key] else { return false }
                editor.updateLayout(layout) { $0.type = type }
            // Copy / cut the open zoom, layout or mask, else copy the frame.
            case ("c", [.command]):
                // Several selected zooms have no single target: the frame is copied instead.
                if editor.selectedZoomIDs.count > 1 { editor.copyCurrentFrame() }
                else if let zoom = editor.selectedZoomIDs.first ?? openZoom { editor.copyZoom(zoom) }
                else if let layout = editor.openLayoutID { editor.copyLayout(layout) }
                else if let mask = editor.openMaskID { editor.copyMask(mask) }
                else if let slice = editor.sliceTarget { editor.copySlice(slice) }
                else { editor.copyCurrentFrame() }
            case ("x", [.command]):
                // A clip is checked first and cannot be cut; several zooms neither.
                if editor.sliceTarget != nil { editor.showToast("Slice cannot be cut"); return true }
                if editor.selectedZoomIDs.count > 1 { return true }
                else if let zoom = editor.selectedZoomIDs.first ?? openZoom { editor.cutZoom(zoom) }
                else if let layout = editor.openLayoutID { editor.cutLayout(layout) }
                else if let mask = editor.openMaskID { editor.cutMask(mask) }
                else { return false }
            case ("v", [.command]):
                return editor.pasteItem()
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
                if let layout = editor.openLayoutID {
                    editor.updateLayout(layout) { $0.isDisabled.toggle() }
                    return true
                }
                guard let openZoom else { return false }
                editor.updateZoom(openZoom) { $0.isDisabled.toggle() }
            case ("c", []):
                // Zoom variant when a zoom is open or under the playhead, otherwise the clip.
                let source = editor.currentSourceTimeMs
                if let mask = editor.openMaskID {
                    editor.splitMask(mask, at: source)
                } else if let layout = editor.openLayoutID {
                    editor.splitLayout(layout, at: source)
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
