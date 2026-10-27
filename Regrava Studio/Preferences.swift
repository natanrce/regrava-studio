import AppKit
import Combine
import RegravaCore
import ServiceManagement

/// What happens when a recording finishes (`actionAfterRecording`).
enum AfterRecordingAction: String, Codable, CaseIterable {
    case createProject = "create-project"
    case exportAndCopyToClipboard = "export-and-copy-to-clipboard"
    case exportAndCreateShareableLink = "export-and-create-shareable-link"
    case exportAndSaveToFile = "export-and-save-to-file"

    var menuTitle: String {
        switch self {
        case .createProject: return "Create project"
        case .exportAndCopyToClipboard: return "Export and copy to clipboard"
        case .exportAndCreateShareableLink: return "Export and create shareable link"
        case .exportAndSaveToFile: return "Export and save to file"
        }
    }

    var startButtonTitle: String {
        switch self {
        case .createProject: return "Start recording"
        case .exportAndCopyToClipboard: return "Record & Copy"
        case .exportAndCreateShareableLink: return "Record & Create Link"
        case .exportAndSaveToFile: return "Record & Save"
        }
    }
}

/// Width × height in points (saved area dimensions).
struct AreaSize: Codable, Hashable {
    var width: Int
    var height: Int
}

/// An area selection on a display, in display-local points (top-left origin).
struct PickedArea: Codable, Hashable {
    var displayID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A keyboard shortcut: modifiers + one key (stored as a display key and macOS key code).
struct KeyShortcut: Codable, Hashable {
    var keyCode: UInt16
    var key: String
    var command = false
    var control = false
    var option = false
    var shift = false

    var hasModifiers: Bool { command || control || option || shift }

    /// macOS order: ⌃⌥⇧⌘ then the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    static func make(_ key: String, keyCode: UInt16, _ modifiers: String = "") -> KeyShortcut {
        KeyShortcut(
            keyCode: keyCode,
            key: key,
            command: modifiers.contains("⌘"),
            control: modifiers.contains("⌃"),
            option: modifiers.contains("⌥"),
            shift: modifiers.contains("⇧")
        )
    }
}

/// Shortcut slots shown in Settings ▸ Shortcuts, with their defaults.
enum ShortcutAction: String, CaseIterable, Codable {
    // Recording (global)
    case recordStartStop, pauseResume, restartRecording, addRecordingMarker
    case recordDisplay, recordWindow, recordArea
    case toggleShowSpeakerNotes, toggleSpeakerNotesPrompter
    case toggleRecordingWidget
    // Editing
    case cutSlice, removeSliceBeforeCut, playOrIncreaseSpeed, playBackwardOrIncreaseSpeed, playOrPause

    var isGlobal: Bool {
        switch self {
        case .cutSlice, .removeSliceBeforeCut, .playOrIncreaseSpeed, .playBackwardOrIncreaseSpeed, .playOrPause: return false
        default: return true
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .recordStartStop: return .make("↩", keyCode: 36, "⌃⌘")
        case .pauseResume: return .make("P", keyCode: 35, "⌥⌘")
        case .restartRecording: return .make("⌫", keyCode: 51, "⌥⌘")
        case .addRecordingMarker: return .make("F", keyCode: 3, "⌃⌥⌘")
        case .recordDisplay: return .make("3", keyCode: 20, "⌥⌘")
        case .recordWindow: return .make("4", keyCode: 21, "⌥⌘")
        case .recordArea: return .make("5", keyCode: 23, "⌥⌘")
        case .toggleShowSpeakerNotes: return .make("/", keyCode: 44, "⌥⌘")
        case .toggleSpeakerNotesPrompter: return .make(".", keyCode: 47, "⌥⌘")
        case .toggleRecordingWidget: return .make("'", keyCode: 39, "⌥⌘")
        case .cutSlice: return .make("C", keyCode: 8)
        case .removeSliceBeforeCut: return .make("X", keyCode: 7)
        case .playOrIncreaseSpeed: return .make("L", keyCode: 37)
        case .playBackwardOrIncreaseSpeed: return .make("J", keyCode: 38)
        case .playOrPause: return .make("K", keyCode: 40)
        }
    }
}

/// App preferences persisted in UserDefaults, with the keys and defaults. Not every key
/// is used by the current phase yet.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []

    // General
    @Published var startAtStartup: Bool
    @Published var hideDockIcon: Bool
    // Recording
    @Published var projectsFolderPath: String?
    @Published var recordingAreaCover: Bool
    @Published var createAutomaticZooms: Bool
    @Published var showRecordingWidget: Bool
    @Published var maximumWebcamHeight: Int
    @Published var recordingCountdownDuration: Int?
    @Published var hideDesktopContentWhileRecording: Bool
    @Published var hideAppDockIconWhileRecording: Bool
    @Published var actionAfterRecording: AfterRecordingAction
    @Published var openRecentProjectsWithRecordingPicker: Bool
    @Published var webcamPreviewType: String
    @Published var showSpeakerNotes: Bool
    /// Timeline waveform.
    @Published var hideAudioWaveform: Bool
    /// `playbackLoop` and `alwaysShowTimelineScrollbar`.
    @Published var playbackLoop: Bool
    @Published var alwaysShowTimelineScrollbar: Bool
    @Published var enableSmoothWaveform: Bool
    /// Options ▸ Advanced ▸ Recording Engine: "auto" (Use Modern Engine If Available) or "modern".
    @Published var recordingEngine: String
    /// Saved area dimensions ("Saved" menu of the area picker).
    @Published var recordingAreaCropPresets: [AreaSize]
    /// Last area selection, restored when "Area" is chosen (`lastPickedArea`).
    @Published var lastPickedArea: PickedArea?
    /// Devices chosen in the record picker (`recordingSourceInput`).
    @Published var recordingCameraID: String?
    @Published var recordingMicrophoneID: String?
    @Published var recordingSystemAudio: Bool
    /// With system audio on: the bundle IDs of the apps recorded, nil for every app
    /// (`systemAudio: "all" | string[]`).
    @Published var recordingSystemAudioApps: [String]?
    // Editing
    @Published var useLastProjectConfigForNewProjects: Bool
    /// Preset applied to new projects ("Use as default for new projects").
    @Published var defaultPresetID: String? {
        didSet { UserDefaults.standard.set(defaultPresetID, forKey: "defaultPresetId") }
    }
    @Published var autoSaveProject: Bool
    @Published var presetsFolderPath: String?
    /// Preview quality factor: 1 (Full), 0.5 (Half), 0.25 (Quarter).
    @Published var playbackPreviewResolution: Double
    /// Preview size steps: 480, 720, 1080, 1440, 2160.
    @Published var playbackPreviewMaxHeight: Int
    /// Zoom level for new zooms (nil = 2).
    @Published var defaultZoomLevel: Double?
    /// The last chosen microphone mode, used by new projects.
    @Published var microphoneAudioPreset: MicrophoneAudioPreset
    // Quick export
    @Published var showQuickExportWidget: Bool
    /// Mutes only the quick export widget's preview.
    @Published var muteQuickExportWidgetPreview: Bool
    @Published var alwaysSaveProjectWhenUsingQuickExportWidget: Bool
    @Published var editProjectTitleWhenUsingQuickExportWidget: Bool
    @Published var exportSettings: ExportSettingsStore
    @Published var widgetExportSettings: ExportSettingsStore
    // Shortcuts (nil = cleared)
    @Published var shortcuts: [ShortcutAction: KeyShortcut?]

    private init() {
        let store = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }
        func decode<T: Decodable>(_ key: String) -> T? {
            store.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }

        startAtStartup = bool("startAtStartup", false)
        hideDockIcon = bool("hideDockIcon", false)
        projectsFolderPath = store.string(forKey: "projectsFolderPath")
        recordingAreaCover = bool("recordingAreaCover", true)
        createAutomaticZooms = bool("createAutomaticZooms", true)
        showRecordingWidget = bool("showRecordingWidget", true)
        maximumWebcamHeight = store.object(forKey: "maximumWebcamHeight") as? Int ?? 1080
        recordingCountdownDuration = store.object(forKey: "recordingCountdownDuration") as? Int
        hideDesktopContentWhileRecording = bool("hideDesktopContentWhileRecording", false)
        hideAppDockIconWhileRecording = bool("hideAppDockIconWhileRecording", true)
        actionAfterRecording = AfterRecordingAction(rawValue: store.string(forKey: "actionAfterRecording") ?? "") ?? .createProject
        openRecentProjectsWithRecordingPicker = bool("openRecentProjectsWithRecordingPicker", false)
        webcamPreviewType = store.string(forKey: "webcamPreviewType") ?? "square"
        showSpeakerNotes = bool("showSpeakerNotes", false)
        hideAudioWaveform = bool("hideAudioWaveform", false)
        playbackLoop = bool("playbackLoop", false)
        alwaysShowTimelineScrollbar = bool("alwaysShowTimelineScrollbar", false)
        enableSmoothWaveform = bool("enableSmoothWaveform", true)
        recordingEngine = store.string(forKey: "recordingUseScreenCaptureKit") ?? "auto"
        recordingAreaCropPresets = decode("recordingAreaCropPresets") ?? []
        lastPickedArea = decode("lastPickedArea")
        recordingCameraID = store.string(forKey: "recordingCameraID")
        recordingMicrophoneID = store.string(forKey: "recordingMicrophoneID")
        recordingSystemAudio = bool("recordingSystemAudio", false)
        recordingSystemAudioApps = decode("recordingSystemAudioApps")
        useLastProjectConfigForNewProjects = bool("useLastProjectConfigForNewProjects", false)
        defaultPresetID = UserDefaults.standard.string(forKey: "defaultPresetId")
        autoSaveProject = bool("autoSaveProject", true)
        presetsFolderPath = store.string(forKey: "presetsFolderPath")
        playbackPreviewResolution = store.object(forKey: "playbackPreviewResolution") as? Double ?? 1
        playbackPreviewMaxHeight = store.object(forKey: "playbackPreviewMaxHeight") as? Int ?? 1080
        defaultZoomLevel = store.object(forKey: "defaultZoomLevel") as? Double
        microphoneAudioPreset = (store.string(forKey: "microphoneAudioPreset")).flatMap(MicrophoneAudioPreset.init(rawValue:)) ?? .voice
        showQuickExportWidget = bool("showQuickExportWidget", true)
        muteQuickExportWidgetPreview = bool("muteQuickExportWidgetPreview", false)
        alwaysSaveProjectWhenUsingQuickExportWidget = bool("alwaysSaveProjectWhenUsingQuickExportWidget", false)
        editProjectTitleWhenUsingQuickExportWidget = bool("editProjectTitleWhenUsingQuickExportWidget", false)
        exportSettings = decode("export-settings") ?? ExportSettingsStore()
        widgetExportSettings = decode("widget-export-settings") ?? ExportSettingsStore()
        let stored: [String: KeyShortcut?] = decode("shortcuts") ?? [:]
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
            (action, stored.keys.contains(action.rawValue) ? stored[action.rawValue]! : action.defaultShortcut)
        })

        objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)
    }

    /// Writes every preference now (also run on quit, ahead of the debounced save).
    func persist() {
        func set(_ key: String, _ value: Any?) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        func encode<T: Encodable>(_ key: String, _ value: T) {
            defaults.set(try? JSONEncoder().encode(value), forKey: key)
        }
        set("startAtStartup", startAtStartup)
        set("hideDockIcon", hideDockIcon)
        set("projectsFolderPath", projectsFolderPath)
        set("recordingAreaCover", recordingAreaCover)
        set("createAutomaticZooms", createAutomaticZooms)
        set("showRecordingWidget", showRecordingWidget)
        set("maximumWebcamHeight", maximumWebcamHeight)
        set("recordingCountdownDuration", recordingCountdownDuration)
        set("hideDesktopContentWhileRecording", hideDesktopContentWhileRecording)
        set("hideAppDockIconWhileRecording", hideAppDockIconWhileRecording)
        set("actionAfterRecording", actionAfterRecording.rawValue)
        set("openRecentProjectsWithRecordingPicker", openRecentProjectsWithRecordingPicker)
        set("webcamPreviewType", webcamPreviewType)
        set("showSpeakerNotes", showSpeakerNotes)
        set("hideAudioWaveform", hideAudioWaveform)
        set("playbackLoop", playbackLoop)
        set("alwaysShowTimelineScrollbar", alwaysShowTimelineScrollbar)
        set("enableSmoothWaveform", enableSmoothWaveform)
        set("recordingUseScreenCaptureKit", recordingEngine)
        encode("recordingAreaCropPresets", recordingAreaCropPresets)
        encode("lastPickedArea", lastPickedArea)
        set("recordingCameraID", recordingCameraID)
        set("recordingMicrophoneID", recordingMicrophoneID)
        set("recordingSystemAudio", recordingSystemAudio)
        encode("recordingSystemAudioApps", recordingSystemAudioApps)
        set("useLastProjectConfigForNewProjects", useLastProjectConfigForNewProjects)
        set("autoSaveProject", autoSaveProject)
        set("presetsFolderPath", presetsFolderPath)
        set("playbackPreviewResolution", playbackPreviewResolution)
        set("playbackPreviewMaxHeight", playbackPreviewMaxHeight)
        set("defaultZoomLevel", defaultZoomLevel)
        set("microphoneAudioPreset", microphoneAudioPreset.rawValue)
        set("showQuickExportWidget", showQuickExportWidget)
        set("muteQuickExportWidgetPreview", muteQuickExportWidgetPreview)
        set("alwaysSaveProjectWhenUsingQuickExportWidget", alwaysSaveProjectWhenUsingQuickExportWidget)
        set("editProjectTitleWhenUsingQuickExportWidget", editProjectTitleWhenUsingQuickExportWidget)
        encode("export-settings", exportSettings)
        encode("widget-export-settings", widgetExportSettings)
        encode("shortcuts", Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }))
    }

    /// "Reset preferences": back to the defaults. Only the preferences are reset; recent
    /// projects, speaker notes and window positions stay.
    func reset() {
        startAtStartup = false
        hideDockIcon = false
        projectsFolderPath = nil
        recordingAreaCover = true
        createAutomaticZooms = true
        showRecordingWidget = true
        maximumWebcamHeight = 1080
        recordingCountdownDuration = nil
        hideDesktopContentWhileRecording = false
        hideAppDockIconWhileRecording = true
        actionAfterRecording = .createProject
        openRecentProjectsWithRecordingPicker = false
        webcamPreviewType = "square"
        showSpeakerNotes = false
        hideAudioWaveform = false
        playbackLoop = false
        alwaysShowTimelineScrollbar = false
        enableSmoothWaveform = true
        recordingEngine = "auto"
        recordingAreaCropPresets = []
        lastPickedArea = nil
        recordingCameraID = nil
        recordingMicrophoneID = nil
        recordingSystemAudio = false
        recordingSystemAudioApps = nil
        useLastProjectConfigForNewProjects = false
        autoSaveProject = true
        presetsFolderPath = nil
        playbackPreviewResolution = 1
        playbackPreviewMaxHeight = 1080
        defaultZoomLevel = nil
        microphoneAudioPreset = .voice
        showQuickExportWidget = true
        muteQuickExportWidgetPreview = false
        alwaysSaveProjectWhenUsingQuickExportWidget = false
        editProjectTitleWhenUsingQuickExportWidget = false
        exportSettings = ExportSettingsStore()
        widgetExportSettings = ExportSettingsStore()
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        defaultPresetID = nil
        persist()
        applyStartAtLogin()
    }

    /// Default projects folder when none is chosen.
    var projectsFolder: URL {
        if let projectsFolderPath { return URL(fileURLWithPath: projectsFolderPath, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Regrava Studio Projects", isDirectory: true)
    }

    /// Registers or unregisters the app as a login item.
    func applyStartAtLogin() {
        do {
            if startAtStartup {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Start at login change failed: \(error.localizedDescription)")
        }
    }
}
