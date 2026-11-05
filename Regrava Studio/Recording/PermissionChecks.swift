import AVFoundation
import AppKit

extension Dialogs {
    /// A message box with the buttons in order; the first is the default, and Escape picks the
    /// button labelled "Cancel" or "No" (else the first). Returns the chosen index after
    /// running its action.
    @discardableResult
    static func messageBox(title: String, message: String, buttons: [(label: String, action: () -> Void)]) -> Int {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        let cancelIndex = buttons.firstIndex { ["cancel", "no"].contains($0.label.lowercased()) } ?? 0
        for (index, button) in buttons.enumerated() {
            let added = alert.addButton(withTitle: button.label)
            if index == cancelIndex, index != 0 { added.keyEquivalent = "\u{1b}" }
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return cancelIndex }
        buttons[index].action()
        return index
    }
}

/// Privacy permissions the recording flow checks.
@MainActor
enum MediaPermission {
    case screen, microphone, camera

    var isDenied: Bool {
        switch self {
        case .screen: return !Permissions.canRecordScreen
        case .microphone: return [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera: return [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    var isAuthorized: Bool {
        switch self {
        case .screen: return Permissions.canRecordScreen
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    /// Asks for the permission, or opens its System Settings pane once it was answered.
    func request() {
        switch self {
        case .screen:
            Permissions.requestScreenRecording()
        case .microphone, .camera:
            let type: AVMediaType = self == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                AVCaptureDevice.requestAccess(for: type) { _ in }
            } else {
                Permissions.openPrivacyPane(self == .camera ? "Privacy_Camera" : "Privacy_Microphone")
            }
        }
    }
}

/// Whether the app can record (Screen Recording and Accessibility), as last checked. It is
/// checked when the picker opens and every 500 ms while it is false; whenever it turns false
/// the picker and Settings close and onboarding is shown.
@MainActor
final class RecordPermissionWatcher {
    static let shared = RecordPermissionWatcher()
    private(set) var canRecord: Bool?
    private var timer: Timer?

    @discardableResult
    func refresh() -> Bool {
        let now = Permissions.canRecord
        let previous = canRecord
        canRecord = now
        if now {
            timer?.invalidate()
            timer = nil
        } else {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated { _ = RecordPermissionWatcher.shared.refresh() }
                }
            }
            if previous != false { lost() }
        }
        return now
    }

    private func lost() {
        AppController.shared.recording.closePicker()
        SettingsWindowController.shared.close()
        OnboardingWindowController.shared.show()
    }
}
