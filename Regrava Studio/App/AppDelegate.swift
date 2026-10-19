import AppKit
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

        let file = NSMenu(title: "File")
        add(to: file, "Open project...", key: "o") { AppController.shared.openProjectPanel() }
        add(to: file, "Open last project", key: "z", modifiers: [.command, .option]) { AppController.shared.openLastProject() }
        file.addItem(.separator())
        add(to: file, "Export...", key: "e", modifiers: [.command, .shift]) { AppController.shared.keyEditor?.model.openExportPicker() }
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
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

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addSubmenu(window, title: "Window", to: main)
        NSApp.windowsMenu = window
        return main
    }

    private func add(to menu: NSMenu, _ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, action: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
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
        case "view":
            builder.group("recording")
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
