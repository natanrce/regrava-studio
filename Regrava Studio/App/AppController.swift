import AppKit
import RegravaCapture
import Combine
import RegravaCore

/// App-wide coordination: recording flow, project windows, recent projects, Dock icon
/// policy and global shortcuts.
@MainActor
final class AppController {
    static let shared = AppController()

    let recording = RecordingCoordinator()
    private(set) var editors: [EditorWindowController] = []
    private(set) var statusItem: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []
    private let preferences = Preferences.shared

    private init() {}

    func launch() {
        // ⌘K with no project open.
        AppCommandMenuPanel.shared.install()
        // iPhones and iPads appear asynchronously once screen capture devices are allowed.
        ExternalDeviceDiscovery.shared.start()
        // Recordings a crash or a quit left unfinished.
        RecordingRecovery.shared.refresh()
        // Projects opened before are listed in the Dock menu too (oldest first, newest on top).
        for url in recentProjects.reversed() { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        statusItem = StatusItemController(coordinator: recording)
        recording.onStateChange = { [weak self] in
            self?.statusItem?.refresh()
            NSApp.dockTile.badgeLabel = self?.recording.isRecording == true ? "●" : nil
        }
        preferences.$shortcuts
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }
            .store(in: &cancellables)
        preferences.$hideDockIcon
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyDockIconPolicy() } }
            .store(in: &cancellables)
        applyDockIconPolicy()
        // The speaker notes window follows its setting, whatever else is open.
        preferences.$showSpeakerNotes
            .sink { visible in DispatchQueue.main.async { SpeakerNotesWindowController.shared.apply(visible) } }
            .store(in: &cancellables)
        recording.$phase
            .sink { [weak self] _ in DispatchQueue.main.async { SpeakerNotesWindowController.shared.setRecording(self?.recording.isRecording == true) } }
            .store(in: &cancellables)

        if Permissions.canRecord {
            recording.openPicker()
        } else {
            OnboardingWindowController.shared.show()
        }
    }

    // MARK: Projects

    /// The editor whose window is in front, for the menu bar (none when another window is).
    var focusedEditor: EditorWindowController? {
        editors.first { $0.window?.isKeyWindow == true || $0.window?.isMainWindow == true }
    }

    var keyEditor: EditorWindowController? {
        editors.first { $0.window?.isKeyWindow == true } ?? editors.last
    }

    /// Quick export widgets open now.
    private(set) var widgets: [QuickExportWidgetController] = []

    /// Opens a project. A normal recording finish (`afterRecording` set) shows the quick export
    /// widget when it is on, which runs the after-recording export; without the widget the editor
    /// opens and no export runs.
    func openProject(bundle: URL, project: Project, afterRecording action: AfterRecordingAction? = nil, isNewRecording: Bool = false, autoplay: Bool = false) {
        if let existing = editors.first(where: { $0.model.bundleURL == bundle }) {
            existing.showWindow(nil)
            return
        }
        if action != nil, preferences.showQuickExportWidget, !widgets.contains(where: { $0.model.bundleURL == bundle }) {
            let widget = QuickExportWidgetController(bundleURL: bundle, project: project, autoAction: action)
            widgets.append(widget)
            rememberRecent(bundle)
            widget.present()
            applyDockIconPolicy()
            return
        }
        let editor = EditorWindowController(bundleURL: bundle, project: project)
        editor.model.isNewRecording = isNewRecording || action != nil
        editors.append(editor)
        rememberRecent(bundle)
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyDockIconPolicy()
        // A new recording autoplays in the editor.
        if autoplay || action != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !editor.model.isPlaying { editor.model.togglePlay() }
            }
        }
    }

    func widgetClosed(_ widget: QuickExportWidgetController) {
        widgets.removeAll { $0 === widget }
        applyDockIconPolicy()
        if editors.isEmpty && widgets.isEmpty && !recording.isRecording { recording.openPicker() }
    }

    func openProject(at bundle: URL) {
        do {
            openProject(bundle: bundle, project: try ProjectStore.load(from: bundle))
        } catch {
            Dialogs.error("Could not open project: \(error.localizedDescription)")
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.projectsFolder
        panel.message = "Choose a .\(ProjectStore.fileExtension) project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recording.closePicker()
        openProject(at: url)
    }

    /// Closes the window of a project (e.g. after it was deleted).
    func closeEditor(for model: EditorModel) {
        guard let controller = editors.first(where: { $0.model === model }) else { return }
        controller.window?.delegate = nil
        controller.close()
        model.tearDown()
        editorClosed(controller)
    }

    func editorRenamed(_ model: EditorModel) {
        editors.first { $0.model === model }?.updateTitle()
        rememberRecent(model.bundleURL)
    }

    func editorClosed(_ editor: EditorWindowController) {
        editors.removeAll { $0 === editor }
        applyDockIconPolicy()
        // When no project is open, the picker comes back.
        if editors.isEmpty && widgets.isEmpty && !recording.isRecording { recording.openPicker() }
    }

    // MARK: Recent projects

    var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var lastProjectURL: URL? {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func rememberRecent(_ url: URL) {
        // Also listed by macOS in the Dock menu and "Open Recent".
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        let kept = Array(paths.prefix(30))
        UserDefaults.standard.set(kept, forKey: "recentProjects")
        var opened = UserDefaults.standard.dictionary(forKey: "recentProjectsOpenedAt") as? [String: Double] ?? [:]
        opened[url.path] = Date().timeIntervalSince1970
        // Only the listed projects keep their opening date.
        let listed = Set(kept)
        opened = opened.filter { listed.contains($0.key) }
        UserDefaults.standard.set(opened, forKey: "recentProjectsOpenedAt")
    }

    /// "Remove from Recents".
    func removeRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: "recentProjects")
        var opened = UserDefaults.standard.dictionary(forKey: "recentProjectsOpenedAt") as? [String: Double] ?? [:]
        opened[url.path] = nil
        UserDefaults.standard.set(opened, forKey: "recentProjectsOpenedAt")
    }

    func openLastProject() {
        guard let url = lastProjectURL else { return }
        recording.closePicker()
        openProject(at: url)
    }

    /// "Show previous projects": reveals the projects folder in Finder.
    /// "Reset windows positions": every remembered window frame and panel position is forgotten,
    /// and the open windows go back to their default places.
    func resetWindowPositions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") || key.hasPrefix("panel.") || key == "quick-export-widget-origin" {
            defaults.removeObject(forKey: key)
        }
        for editor in editors { editor.window?.center() }
        widgets.forEach { $0.window?.center() }
    }

    func showPreviousProjects() {
        let folder = preferences.projectsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Dock & shortcuts

    /// Hidden Dock icon when "Hide Dock Icon" is on and nothing is open, or while recording with
    /// "Hide Dock Icon" (while recording) on.
    func applyDockIconPolicy() {
        let hideWhileRecording = recording.isRecording && preferences.hideAppDockIconWhileRecording
        let hideIdle = preferences.hideDockIcon && editors.isEmpty && widgets.isEmpty
        NSApp.setActivationPolicy(hideWhileRecording || hideIdle ? .accessory : .regular)
    }

    func registerHotKeys() {
        let recording = self.recording
        var bindings: [(KeyShortcut, () -> Void)] = []
        func bind(_ action: ShortcutAction, _ handler: @escaping () -> Void) {
            if let shortcut = preferences.shortcuts[action] ?? nil { bindings.append((shortcut, handler)) }
        }
        bind(.recordStartStop) { recording.isRecording ? recording.requestFinish() : recording.openPicker() }
        bind(.pauseResume) { recording.togglePause() }
        bind(.restartRecording) { recording.requestRestart() }
        bind(.addRecordingMarker) { recording.addMarker() }
        bind(.recordDisplay) { recording.openPicker(preselect: .display) }
        bind(.recordWindow) { recording.openPicker(preselect: .window) }
        bind(.recordArea) { recording.openPicker(preselect: .area) }
        bind(.toggleRecordingWidget) { Preferences.shared.showRecordingWidget.toggle() }
        bind(.toggleShowSpeakerNotes) { Preferences.shared.showSpeakerNotes.toggle() }
        bind(.toggleSpeakerNotesPrompter) { SpeakerNotesStore.shared.togglePlaying() }
        GlobalHotKeys.shared.register(bindings)
    }
}
