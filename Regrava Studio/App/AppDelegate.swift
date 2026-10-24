import AppKit
import SwiftUI
import RegravaCore

/// AppKit lifecycle:, there is no main window — the record picker opens on launch and
/// every project opens in its own editor window.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app has a dark-only theme.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = buildMainMenu()
        if UISnapshots.runIfRequested() { return }
        AppController.shared.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-recording interrupts it; its folder is recovered on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppController.shared.recording.isRecording else { return .terminateNow }
        let quit = Dialogs.confirm(
            title: "Regrava Studio",
            message: "A recording is still in progress. Quitting now will interrupt it (the footage can be recovered on next launch). Quit anyway?",
            confirm: "Quit",
            cancel: "Cancel",
            destructive: true
        )
        return quit ? .terminateNow : .terminateCancel
    }

    /// Clicking the Dock icon while recording asks to finish.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let recording = AppController.shared.recording
        if recording.isRecording {
            if Dialogs.confirm(title: "Finish recording?", message: "The recording will open in the editor.", confirm: "Finish", cancel: "Continue Recording") {
                recording.requestFinish()
            }
        } else if !flag {
            recording.openPicker()
        }
        return true
    }

    /// Dock menu. Projects opened from Finder or the Dock's recent documents.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == ProjectStore.fileExtension {
            AppController.shared.recording.closePicker()
            AppController.shared.openProject(at: url)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let app = AppController.shared
        let recording = app.recording
        let menu = MenuBuilder()
        if recording.isRecording {
            menu.item("Stop recording") { recording.requestFinish() }
            menu.item("Finish recording") { recording.requestFinish() }
            menu.item("Cancel recording") { recording.requestCancel() }
            menu.item("Restart recording") { recording.requestRestart() }
            menu.group("settings")
        }
        // Dock menu order.
        menu.item("Show Regrava Studio in Dock", checked: !Preferences.shared.hideDockIcon) {
            Preferences.shared.hideDockIcon.toggle()
            app.applyDockIconPolicy()
        }
        menu.item("Open last project", enabled: app.lastProjectURL != nil) { app.openLastProject() }
        menu.item("Show settings") { SettingsWindowController.shared.show() }
        if !recording.isRecording {
            menu.item("New recording...") { recording.openPicker() }
        }
        return menu.menu
    }

    // MARK: Main menu

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Regrava Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(to: appMenu, "Settings…", key: ",") { SettingsWindowController.shared.show() }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Regrava Studio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Regrava Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, title: "Regrava Studio", to: main)

        // File: items that cannot apply are hidden.
        let file = NSMenu(title: "File")
        file.identifier = NSUserInterfaceItemIdentifier("file")
        file.delegate = self
        let recent = NSMenuItem(title: "Open recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open recent")
        file.addItem(recent)
        recentItem = recent
        file.addItem(.separator())
        recoverItem = conditional(file, "Recover unfinished recordings", icon: "arrow.up.circle", available: { !RecordingRecovery.shared.unfinished.isEmpty }) {
            Task { await RecordingRecovery.shared.recoverAll() }
        }
        add(to: file, "Open project...", key: "o") { AppController.shared.openProjectPanel() }
        conditional(file, "Open last project", key: "z", modifiers: [.command, .option], available: { AppController.shared.lastProjectURL != nil }) { AppController.shared.openLastProject() }
        add(to: file, "Show previous projects") { AppController.shared.showPreviousProjects() }
        file.addItem(.separator())
        project(file, "Save", key: "s") { $0.saveFromMenu() }
        project(file, "Save as...", key: "s", modifiers: [.command, .shift]) { $0.saveAs() }
        project(file, "Show project in Finder", key: "o", modifiers: [.command, .shift], icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([$0.bundleURL]) }
        file.addItem(.separator())
        project(file, "Remove project", icon: "trash") { model in
            guard model.deleteProject() else { return }
            AppController.shared.closeEditor(for: model)
        }
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(file, title: "File", to: main)

        // Edit: the project's Undo/Redo, hidden when there is nothing to undo; text fields keep
        // their own undo.
        let edit = NSMenu(title: "Edit")
        edit.identifier = NSUserInterfaceItemIdentifier("edit")
        edit.delegate = self
        conditional(edit, "Undo", key: "z", icon: "arrow.uturn.backward", available: { Self.textUndo.map { $0.canUndo } ?? AppController.shared.focusedEditor?.model.canUndo ?? false }) {
            if let undo = Self.textUndo { undo.undo() } else { AppController.shared.focusedEditor?.model.undo() }
        }
        conditional(edit, "Redo", key: "z", modifiers: [.command, .shift], icon: "arrow.uturn.forward", available: { Self.textUndo.map { $0.canRedo } ?? AppController.shared.focusedEditor?.model.canRedo ?? false }) {
            if let undo = Self.textUndo { undo.redo() } else { AppController.shared.focusedEditor?.model.redo() }
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, title: "Edit", to: main)

        let record = NSMenu(title: "Record")
        record.delegate = self
        record.identifier = NSUserInterfaceItemIdentifier("record")
        addSubmenu(record, title: "Record", to: main)

        let view = NSMenu(title: "View")
        view.delegate = self
        view.identifier = NSUserInterfaceItemIdentifier("view")
        addSubmenu(view, title: "View", to: main)

        // Export.
        let export = NSMenu(title: "Export")
        export.identifier = NSUserInterfaceItemIdentifier("export")
        export.delegate = self
        project(export, "Export...", key: "e", modifiers: [.command, .shift], available: { !$0.exports.isExporting }) { $0.openExportPicker() }
        project(export, "Quick export to clipboard", key: "c", modifiers: [.command, .option], available: { !$0.exports.isExporting }) { $0.quickExport(.clipboard) }
        project(export, "Quick export to file...", key: "s", modifiers: [.command, .option], available: { !$0.exports.isExporting }) { $0.quickExport(.file) }
        add(to: export, "Show previous clipboard exports") { ExportController.revealClipboardExports() }
        export.addItem(.separator())
        project(export, "Export current frame as image...", icon: "square.and.arrow.up") { $0.exportCurrentFrame() }
        export.addItem(.separator())
        add(to: export, "Open recent Clipboard exports") { ExportController.revealClipboardExports() }
        addSubmenu(export, title: "Export", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addSubmenu(window, title: "Window", to: main)
        NSApp.windowsMenu = window
        return main
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    /// File → "Recover N unfinished recordings", hidden when there are none (`canApply`).
    private var recoverItem: NSMenuItem?
    private var recentItem: NSMenuItem?

    /// The undo manager of a focused text field, which keeps its own Undo/Redo.
    private static var textUndo: UndoManager? {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text.undoManager
    }

    /// An item hidden while `available` is false.
    @discardableResult
    private func conditional(_ menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, icon: String? = nil, available: @escaping () -> Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = add(to: menu, title, key: key, modifiers: modifiers, action: action)
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        (item as? ClosureMenuItem)?.isAvailable = available
        (item as? ClosureMenuItem)?.hidesWhenUnavailable = true
        return item
    }

    /// An item acting on the focused project, hidden without one.
    @discardableResult
    private func project(_ menu: NSMenu, _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, icon: String? = nil, available: @escaping (EditorModel) -> Bool = { _ in true }, action: @escaping (EditorModel) -> Void) -> NSMenuItem {
        conditional(menu, title, key: key, modifiers: modifiers, icon: icon, available: {
            AppController.shared.focusedEditor.map { available($0.model) } ?? false
        }) {
            if let model = AppController.shared.focusedEditor?.model { action(model) }
        }
    }

    /// Hides unavailable items, and separators left at an edge or next to another.
    private func updateVisibility(_ menu: NSMenu) {
        for case let item as ClosureMenuItem in menu.items where item.hidesWhenUnavailable {
            item.isHidden = !(item.isAvailable?() ?? true)
        }
        var lastVisibleWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                item.isHidden = lastVisibleWasSeparator
                if !item.isHidden { lastVisibleWasSeparator = true }
            } else if !item.isHidden {
                lastVisibleWasSeparator = false
            }
        }
        if let last = menu.items.last(where: { !$0.isHidden }), last.isSeparatorItem { last.isHidden = true }
    }

    /// "Open recent ▸": one item per recent project; a missing one says so.
    private func rebuildRecent() {
        guard let recentItem, let submenu = recentItem.submenu else { return }
        submenu.removeAllItems()
        let recents = AppController.shared.recentProjects
        recentItem.isHidden = recents.isEmpty
        for url in recents {
            let item = ClosureMenuItem(title: url.deletingPathExtension().lastPathComponent) {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    Dialogs.info(title: "Failed to open project", message: "Project file was not found. It might have been moved or deleted")
                    return
                }
                AppController.shared.recording.closePicker()
                AppController.shared.openProject(at: url)
            }
            item.image = NSApp.applicationIconImage.copy() as? NSImage
            item.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(item)
        }
    }

    private func addSubmenu(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    /// "Record" and "View" menus are rebuilt on open so checks stay current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let recording = AppController.shared.recording
        let preferences = Preferences.shared
        let shortcuts = preferences.shortcuts
        let builder = MenuBuilder()
        switch menu.identifier?.rawValue {
        case "record":
            builder.group("recording-new")
            builder.item(recording.isRecording ? "Stop recording" : "New recording...", icon: "record.circle", shortcut: shortcuts[.recordStartStop] ?? nil) {
                recording.isRecording ? recording.requestFinish() : recording.openPicker()
            }
            builder.group("recording")
            builder.item("Record display", icon: "dock.rectangle", enabled: !recording.isRecording, shortcut: shortcuts[.recordDisplay] ?? nil) { recording.openPicker(preselect: .display) }
            builder.item("Record window", icon: "macwindow", enabled: !recording.isRecording, shortcut: shortcuts[.recordWindow] ?? nil) { recording.openPicker(preselect: .window) }
            builder.item("Record area", icon: "square.dashed", enabled: !recording.isRecording, shortcut: shortcuts[.recordArea] ?? nil) { recording.openPicker(preselect: .area) }
            builder.group("after")
            builder.header("After Recording")
            for action in [AfterRecordingAction.createProject, .exportAndCopyToClipboard, .exportAndSaveToFile] {
                builder.item(action.menuTitle, checked: preferences.actionAfterRecording == action) { preferences.actionAfterRecording = action }
            }
            builder.group("settings-zooms")
            builder.item("Automatically create zooms", checked: preferences.createAutomaticZooms) { preferences.createAutomaticZooms.toggle() }
        case "file":
            let recovery = RecordingRecovery.shared
            recovery.refresh()
            recoverItem?.title = recovery.actionName
            rebuildRecent()
            updateVisibility(menu)
            return
        case "edit", "export":
            updateVisibility(menu)
            return
        case "view":
            // Sidebar panels ⌘1…⌘0, shown disabled when not applicable (`showIfDisabled`); Camera
            // Style is not in the menu.
            if let editor = AppController.shared.focusedEditor?.model {
                builder.group("sidebar")
                for entry in editor.railEntries where entry.root != .cameraStyle {
                    let item = builder.item(entry.name, icon: entry.icon, checked: editor.sidebarRoot == entry.root && editor.layoutType.showsSidebar, enabled: entry.disabledTooltip == nil) {
                        editor.openSidebar(entry.root)
                    }
                    item.keyEquivalent = String(entry.key.character)
                    item.keyEquivalentModifierMask = .command
                }
            }
            // "editor" group.
            if let editor = AppController.shared.focusedEditor?.model {
                builder.group("editor")
                builder.item("Show editor sidebar", icon: "sidebar.right", checked: editor.layoutType.showsSidebar) { editor.toggleSidebarShown() }
                builder.item("Loop playback", icon: "repeat", checked: preferences.playbackLoop) { preferences.playbackLoop.toggle() }
                builder.item("Show editor timeline", icon: "timeline.selection", checked: editor.layoutType.showsTimeline) { editor.toggleTimelineShown() }
                builder.item("Always show timeline scrollbar", icon: "chevron.up.chevron.down", checked: preferences.alwaysShowTimelineScrollbar) { preferences.alwaysShowTimelineScrollbar.toggle() }
            }
            // Only while an editor is open (no `showIfDisabled`).
            if AppController.shared.keyEditor != nil {
                builder.group("editor-waveform")
                builder.item("Show audio waveform", icon: "waveform", checked: !preferences.hideAudioWaveform) { preferences.hideAudioWaveform.toggle() }
                builder.item("Smooth waveform", icon: "waveform", checked: preferences.enableSmoothWaveform) { preferences.enableSmoothWaveform.toggle() }
            }
            builder.group("recording")
            builder.item(preferences.showSpeakerNotes ? "Hide speaker notes" : "Show speaker notes", icon: "text.bubble", checked: preferences.showSpeakerNotes, shortcut: shortcuts[.toggleShowSpeakerNotes] ?? nil) {
                preferences.showSpeakerNotes.toggle()
            }
            builder.item("Show recording widget", icon: "menubar.dock.rectangle.badge.record", checked: preferences.showRecordingWidget, shortcut: shortcuts[.toggleRecordingWidget] ?? nil) {
                preferences.showRecordingWidget.toggle()
            }
        default:
            return
        }
        menu.removeAllItems()
        for item in builder.menu.items {
            builder.menu.removeItem(item)
            menu.addItem(item)
        }
    }
}
