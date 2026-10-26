import AppKit
import RegravaCore

/// `regrava-studio://<command>` links: each command runs the matching action when it can apply.
@MainActor
enum DeepLinks {
    static let scheme = "regrava-studio"

    static func handle(_ url: URL) {
        guard url.scheme == scheme, let command = url.host ?? url.pathComponents.dropFirst().first else { return }
        let app = AppController.shared
        let recording = app.recording
        let preferences = Preferences.shared
        let editor = app.focusedEditor?.model ?? app.keyEditor?.model
        switch command {
        case "record-display": if !recording.isRecording { recording.openPicker(preselect: .display) }
        case "record-window": if !recording.isRecording { recording.openPicker(preselect: .window) }
        case "record-area": if !recording.isRecording { recording.openPicker(preselect: .area) }
        case "finish-recording": if recording.isRecording { recording.requestFinish() }
        case "cancel-recording": if recording.isRecording { recording.requestCancel() }
        case "restart-recording": if recording.isRecording { recording.requestRestart() }
        case "toggle-recording-controls": preferences.showRecordingWidget.toggle()
        case "toggle-speaker-notes": preferences.showSpeakerNotes.toggle()
        case "toggle-recording-area-cover": preferences.recordingAreaCover.toggle()
        case "open-settings": SettingsWindowController.shared.show()
        case "open-projects-folder": app.showPreviousProjects()
        case "copy-and-zip-project": editor?.copyAndZipProject()
        // "with current settings": the export picker's settings, not the quick export ones.
        case "export-to-file": editor?.exportWithCurrentSettings(.file)
        case "export-to-clipboard": editor?.exportWithCurrentSettings(.clipboard)
        default: break
        }
    }
}
