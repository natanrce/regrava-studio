import AppKit
import Combine
import RegravaCapture
import RegravaCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Screen {
        case recorder
        case editor(EditorModel)
    }

    @Published var screen: Screen = .recorder
    @Published var displays: [DisplayInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var options = CaptureOptions()
    @Published var createsAutomaticZooms: Bool {
        didSet { UserDefaults.standard.set(createsAutomaticZooms, forKey: "createsAutomaticZooms") }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var errorMessage: String?

    private let recorder = ScreenRecorder()
    private var pendingBundle: URL?

    init() {
        createsAutomaticZooms = UserDefaults.standard.object(forKey: "createsAutomaticZooms") as? Bool ?? true
    }

    static var projectsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("Regrava Studio", isDirectory: true)
    }

    func loadDisplays() async {
        do {
            displays = try await ScreenRecorder.availableDisplays()
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first?.id
            }
        } catch {
            errorMessage = "Could not list displays: \(error.localizedDescription)\nGrant Screen Recording permission in System Settings › Privacy & Security."
        }
    }

    func startRecording() async {
        guard let displayID = selectedDisplayID, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let bundle = Self.projectsDirectory
            .appendingPathComponent("Recording \(formatter.string(from: Date())).\(ProjectStore.fileExtension)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try await recorder.start(displayID: displayID, options: options, outputURL: bundle.appendingPathComponent("recording.mov"))
            pendingBundle = bundle
            isRecording = true
            recordingStartedAt = Date()
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording, let bundle = pendingBundle else { return }
        isBusy = true
        defer { isBusy = false }
        isRecording = false
        recordingStartedAt = nil
        do {
            let result = try await recorder.stop()
            var project = Project(
                recording: RecordingInfo(
                    videoFileName: result.videoURL.lastPathComponent,
                    videoSize: result.videoSize,
                    pointPixelScale: result.pointPixelScale,
                    durationMs: result.durationMs,
                    fps: result.fps
                ),
                mouseEvents: result.mouseEvents
            )
            project.autoZoom.isEnabled = createsAutomaticZooms
            project.regenerateAutomaticZooms()
            try ProjectStore.save(project, to: bundle)
            open(bundle: bundle, project: project)
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
        pendingBundle = nil
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.projectsDirectory
        panel.message = "Choose a .regrava project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            open(bundle: url, project: try ProjectStore.load(from: url))
        } catch {
            errorMessage = "Could not open project: \(error.localizedDescription)"
        }
    }

    func open(bundle: URL, project: Project) {
        let editor = EditorModel(bundleURL: bundle, project: project)
        screen = .editor(editor)
        Task { await editor.prepare() }
    }

    func closeEditor() {
        if case .editor(let editor) = screen { editor.saveNow() }
        screen = .recorder
    }
}
