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
    private var statusItem: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []
    private let preferences = Preferences.shared

    private init() {}

    func launch() {
        // iPhones and iPads appear asynchronously once screen capture devices are allowed.
        ExternalDeviceDiscovery.shared.start()
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

        if Permissions.canRecord {
            recording.openPicker()
        } else {
            OnboardingWindowController.shared.show()
        }
    }

    // MARK: Projects

    var keyEditor: EditorWindowController? {
        editors.first { $0.window?.isKeyWindow == true } ?? editors.last
    }

    func openProject(bundle: URL, project: Project, afterRecording action: AfterRecordingAction? = nil) {
        if let existing = editors.first(where: { $0.model.bundleURL == bundle }) {
            existing.showWindow(nil)
            return
        }
        let editor = EditorWindowController(bundleURL: bundle, project: project)
        editors.append(editor)
        rememberRecent(bundle)
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyDockIconPolicy()

        // After-recording action with the quick export settings.
        let settings = preferences.widgetExportSettings.current
        switch action {
        case .exportAndCopyToClipboard:
            editor.model.exports.start(project: project, videoURL: editor.model.videoURL, projectName: editor.model.projectName, settings: settings, target: .clipboard)
        case .exportAndSaveToFile:
            editor.model.exports.start(project: project, videoURL: editor.model.videoURL, projectName: editor.model.projectName, settings: settings, target: .file)
        default:
            break
        }
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
        if editors.isEmpty && !recording.isRecording { recording.openPicker() }
    }

    // MARK: Recent projects

    var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var lastProjectURL: URL? { recentProjects.first }

    private func rememberRecent(_ url: URL) {
        // Also listed by macOS in the Dock menu and "Open Recent".
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(30)), forKey: "recentProjects")
        var opened = UserDefaults.standard.dictionary(forKey: "recentProjectsOpenedAt") as? [String: Double] ?? [:]
        opened[url.path] = Date().timeIntervalSince1970
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
        let hideIdle = preferences.hideDockIcon && editors.isEmpty
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
        GlobalHotKeys.shared.register(bindings)
    }
}
