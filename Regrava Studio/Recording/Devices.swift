@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics

struct CaptureDeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var isDefault: Bool
}

/// Cameras and microphones, default first then by name.
enum DeviceCatalog {
    static func cameras() -> [CaptureDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        return sorted(session.devices, defaultID: AVCaptureDevice.default(for: .video)?.uniqueID)
    }

    static func microphones() -> [CaptureDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return sorted(session.devices, defaultID: AVCaptureDevice.default(for: .audio)?.uniqueID)
    }

    private static func sorted(_ devices: [AVCaptureDevice], defaultID: String?) -> [CaptureDeviceInfo] {
        devices
            .map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
            .sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
}

/// Permission checks used by the picker and onboarding.
enum Permissions {
    static var canRecordScreen: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    /// Onboarding requires both.
    static var canRecord: Bool { canRecordScreen && hasAccessibility }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Requests access when undetermined; returns whether access is granted.
    static func ensureAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }
}

/// Live microphone level for the picker's level bar and the menu's level rows
/// (MicrophoneVolumePreview). Level is 0…1 mapped from dBFS.
@MainActor
final class MicrophoneLevelMonitor: NSObject, ObservableObject {
    @Published private(set) var level: Double = 0
    /// Smoothed peak shown behind the instantaneous level.
    @Published private(set) var peak: Double = 0
    /// No data for 7 s or silence (≤ −100 dB) → warning icon.
    @Published private(set) var isSilent = false

    private var session: AVCaptureSession?
    private var deviceID: String?
    private let delegate = AudioLevelDelegate()
    private var lastSignal = Date()
    private var watchdog: Timer?

    func monitor(deviceID: String?) {
        guard deviceID != self.deviceID else { return }
        stop()
        self.deviceID = deviceID
        guard let deviceID, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = AVCaptureDevice(uniqueID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        delegate.onLevel = { [weak self] decibels in
            Task { @MainActor in self?.receive(decibels) }
        }
        output.setSampleBufferDelegate(delegate, queue: delegate.queue)
        self.session = session
        lastSignal = Date()
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastSignal) > 7 { self.isSilent = true }
            }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let session { DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() } }
        session = nil
        deviceID = nil
        level = 0
        peak = 0
        isSilent = false
    }

    private func receive(_ decibels: Float) {
        let db = Double(decibels)
        if db > -100 { lastSignal = Date() }
        isSilent = db <= -100 && Date().timeIntervalSince(lastSignal) > 7
        let normalized = max(0, min(1, (db + 60) / 60))
        level = normalized
        peak = max(normalized, peak * 0.92)
    }
}

private final class AudioLevelDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "regrava.microphone.level")
    var onLevel: ((Float) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let channel = connection.audioChannels.first else { return }
        onLevel?(channel.averagePowerLevel)
    }
}
