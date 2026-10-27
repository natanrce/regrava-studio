import AppKit
import Combine
import RegravaCapture
import RegravaCore
import SwiftUI

/// Recording folders and their recovery: recordings are written into "Regrava Studio
/// Recordings In Progress" and become a project only once finalized, so every folder left
/// there is one that no finish ended (a crash or a quit).
@MainActor
enum RecordingFolders {
    /// `~/Library/Application Support/Regrava Studio/Regrava Studio Recordings In Progress`.
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Regrava Studio", isDirectory: true)
            .appendingPathComponent("Regrava Studio Recordings In Progress", isDirectory: true)
    }

    /// The app's own data about a recording, kept in its folder (`screen-studio-recording.json`:
    /// `{appData, markers}`) so a project can be made from it without the app's memory.
    struct AppData: Codable {
        /// "<Name> yyyy-MM-dd HH.mm.ss", the project's name.
        var projectName: String
        /// "display", "window" or "device".
        var mode: String
    }

    private struct Marker: Codable {
        var appData: String
        var markers: [Double]
    }

    static let markerFileName = "regrava-studio-recording.json"

    /// A new folder "<Name> yyyy-MM-dd HH:mm:ss" (it must not exist yet).
    static func makeFolder(name: String, mode: String) throws -> URL {
        let date = Date()
        let folderFormat = DateFormatter()
        folderFormat.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let projectFormat = DateFormatter()
        projectFormat.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var folder = root.appendingPathComponent("\(name) \(folderFormat.string(from: date))", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(name) \(folderFormat.string(from: date)) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appData = AppData(projectName: "\(name) \(projectFormat.string(from: date))", mode: mode)
        let json = String(decoding: try JSONEncoder().encode(appData), as: UTF8.self)
        try JSONEncoder().encode(Marker(appData: json, markers: [])).write(to: folder.appendingPathComponent(markerFileName))
        return folder
    }

    /// Nil for a folder of an app version that did not keep it.
    static func appData(of folder: URL) -> AppData? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(markerFileName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        return try? JSONDecoder().decode(AppData.self, from: Data(marker.appData.utf8))
    }

    /// `listUnfinished`: the folders no finish ended, newest first. `excluding` is the folder of
    /// the recording in progress, which is not unfinished.
    static func unfinished(excluding current: URL? = nil) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.standardizedFileURL != current?.standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(RecordingMetadata.fileName).path) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    /// Makes the project from a finalized recording: a new bundle in the projects folder with the
    /// movie, webcam and cursor images moved in, then the folder is removed.
    static func createProject(from result: CaptureResult, folder: URL) throws -> (bundle: URL, project: Project) {
        let preferences = Preferences.shared
        let appData = appData(of: folder)
        let name = appData?.projectName ?? folder.lastPathComponent.replacingOccurrences(of: ":", with: ".")
        try FileManager.default.createDirectory(at: preferences.projectsFolder, withIntermediateDirectories: true)
        var bundle = preferences.projectsFolder.appendingPathComponent("\(name).\(ProjectStore.fileExtension)", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: bundle.path) {
            bundle = preferences.projectsFolder.appendingPathComponent("\(name) \(suffix).\(ProjectStore.fileExtension)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let video = bundle.appendingPathComponent(result.videoURL.lastPathComponent)
        try FileManager.default.moveItem(at: result.videoURL, to: video)
        var cameraName: String?
        if let camera = result.cameraURL {
            try FileManager.default.moveItem(at: camera, to: bundle.appendingPathComponent(camera.lastPathComponent))
            cameraName = camera.lastPathComponent
        }
        var cursors: [RecordedCursor] = []
        for image in result.customCursors {
            let url = ProjectStore.cursorImageURL(bundle: bundle, id: image.id)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? image.pngData.write(to: url)) != nil else { continue }
            cursors.append(RecordedCursor(id: image.id, hotSpot: image.hotSpot, standardSize: image.size))
        }
        let mode: RecordingMode = result.externalDevice != nil ? .externalDevice : appData?.mode == "window" ? .window : .display
        var project = Project(
            recording: RecordingInfo(
                videoFileName: video.lastPathComponent,
                videoSize: result.videoSize,
                pointPixelScale: result.pointPixelScale,
                durationMs: result.durationMs,
                fps: result.fps,
                cursors: cursors,
                audioSources: result.audioSources,
                cameraFileName: cameraName,
                cameraSize: result.cameraSize,
                mode: mode,
                externalDevice: result.externalDevice,
                flags: result.flags
            ),
            mouseEvents: result.mouseEvents,
            markersMs: result.markersMs,
            keystrokes: result.keystrokes
        )
        project.recording.sessionStartsMs = result.sessionStartsMs
        // New projects start from the default preset, or the last edited settings.
        if let preset = PresetStore.shared.defaultPreset {
            PresetStore.shared.copyAssets(of: preset, into: bundle)
            project.apply(preset.preset.config)
        } else if preferences.useLastProjectConfigForNewProjects,
                  let data = UserDefaults.standard.data(forKey: "lastProjectConfig"),
                  let config = try? JSONDecoder().decode(PresetConfig.self, from: data) {
            project.apply(config)
        }
        // New projects use the last chosen microphone mode, unless their config set one.
        if !preferences.useLastProjectConfigForNewProjects { project.audio.microphoneAudioPreset = preferences.microphoneAudioPreset }
        project.autoZoom.isEnabled = preferences.createAutomaticZooms
        project.regenerateAutomaticZooms()
        try ProjectStore.save(project, to: bundle)
        try? FileManager.default.removeItem(at: folder)
        return (bundle, project)
    }
}

/// The unfinished recordings and the flows that recover them.
@MainActor
final class RecordingRecovery: ObservableObject {
    static let shared = RecordingRecovery()

    @Published private(set) var unfinished: [URL] = []

    func refresh() {
        let list = RecordingFolders.unfinished(excluding: AppController.shared.recording.recordingFolder)
        if list != unfinished { unfinished = list }
    }

    /// `Recover N unfinished recording(s)`, else "Recover unfinished recordings".
    var actionName: String {
        let n = unfinished.count
        return n > 0 ? "Recover \(n) unfinished recording\(n == 1 ? "" : "s")" : "Recover unfinished recordings"
    }

    /// `recoverUnfinishedRecording`: each folder in turn.
    func recoverAll() async {
        refresh()
        guard !unfinished.isEmpty else {
            Dialogs.info(title: "No unfinished recordings found", message: "No unfinished recordings found")
            return
        }
        for folder in unfinished { await offer(folder) }
        refresh()
    }

    /// Confirm, then "Are you sure?" before deleting.
    private func offer(_ folder: URL) async {
        let name = folder.lastPathComponent
        if Dialogs.confirm(title: "Regrava Studio found unfinished recording", message: "Do you want to recover recording? (\(name))", confirm: "Recover recording", cancel: "Delete and don't recover") {
            await recover(folder)
            return
        }
        if Dialogs.confirm(title: "Are you sure?", message: "When you delete unfinished recording, it will be deleted from your computer and it will not be recoverable. (\(name))", confirm: "Recover recording", cancel: "Delete and don't recover") {
            await recover(folder)
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// `tryToRecoverRecordingFromRecordingFolder`.
    func recoverFromPickedFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select recording folder"
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        await recover(folder)
    }

    /// Finalize under the "Recovering recording" loader; open it, or say why not and show the
    /// folder, which is kept.
    func recover(_ folder: URL) async {
        LoaderWindow.shared.show("Recovering recording")
        var opened: (URL, Project)?
        if let result = try? await RecordingFinalizer.finalize(folder: folder) {
            opened = try? RecordingFolders.createProject(from: result, folder: folder)
        }
        LoaderWindow.shared.hide()
        refresh()
        guard let (bundle, project) = opened else {
            Dialogs.info(title: "Recording can't be recovered", message: "Recording at path \"\(folder.path)\" can't be recovered.")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return
        }
        AppController.shared.openProject(bundle: bundle, project: project)
    }
}

/// The global loader (`setLoaderMessage`): a small floating panel with a spinner and a message.
@MainActor
final class LoaderWindow {
    static let shared = LoaderWindow()
    private var panel: NSPanel?

    func show(_ message: String) {
        let view = HStack(spacing: Theme.gap(1)) {
            ProgressView().controlSize(.small)
            Text(message).font(Theme.Typo.controlCopy)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
