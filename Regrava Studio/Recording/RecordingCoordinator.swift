import AVFoundation
import AppKit
import Combine
import RegravaCapture
import RegravaCore
@preconcurrency import ScreenCaptureKit
import SwiftUI

enum SourceType: String, CaseIterable {
    case display, window, area, device

    var label: String {
        switch self {
        case .display: return "Display"
        case .window: return "Window"
        case .area: return "Area"
        case .device: return "Device"
        }
    }

    var icon: String {
        switch self {
        case .display: return "dock.rectangle"
        case .window: return "macwindow"
        case .area: return "square.dashed"
        case .device: return "apps.iphone"
        }
    }
}

enum RecordSelection: Equatable {
    case display(DisplayInfo)
    case window(WindowInfo)
    /// Rect in display-local points.
    case area(displayID: CGDirectDisplayID, rect: CGRect)
    /// An iPhone or iPad connected by cable (`{type: "device", deviceId}`).
    case device(id: String)

    /// Global (Quartz, top-left origin) bounds of what is recorded; nil for a device.
    var globalBounds: CGRect? {
        switch self {
        case .display(let display): return display.frame
        case .window(let window): return window.frame
        case let .area(id, rect):
            let origin = CGDisplayBounds(id).origin
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        case .device: return nil
        }
    }

    var captureSource: CaptureSource? {
        switch self {
        case .display(let display): return .display(display.id)
        case .window(let window): return .window(window.id)
        case let .area(id, rect): return .area(displayID: id, rect: rect)
        case .device: return nil
        }
    }
}

/// State and actions of the recording flow: picker, source selection, countdown, recording
/// controls and the after-recording action.
@MainActor
final class RecordingCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(total: Int, startedAt: Date)
        case starting
        case recording
        case paused
        case working
        case finishing
    }

    static let minimumAreaSize: CGFloat = 150

    // Picker
    @Published private(set) var isPickerOpen = false
    @Published private(set) var sourceType: SourceType?
    @Published var selection: RecordSelection?
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published var ignoredWindowIDs: Set<CGWindowID> = []
    @Published private(set) var cameras: [CaptureDeviceInfo] = []
    @Published private(set) var microphones: [CaptureDeviceInfo] = []
    /// App state, not persisted.
    @Published var showCameraPreview = true
    // Recording
    @Published private(set) var phase: Phase = .idle
    /// The recording's elapsed time, observed only by the timer that shows it.
    let clock = RecordingClock()
    /// True while an operation has been running for ≥ 3 s ("Working...").
    @Published private(set) var showsWorking = false
    @Published private(set) var flagFlash = false

    let preferences = Preferences.shared
    let microphoneLevel = MicrophoneLevelMonitor()
    private let recorder = ScreenRecorder()
    private let deviceRecorder = ExternalDeviceRecorder()
    let externalDevices = ExternalDeviceDiscovery.shared
    private var pickerPanel: GlassPanel<RecordingPickerView>?
    private var pickerKeyMonitor: Any?
    private var recentProjectsPanel: RecentProjectsPanel?
    private var widgetPanel: GlassPanel<RecordingWidgetView>?
    private lazy var overlays = SourceOverlayController(coordinator: self)
    private lazy var boundsIndicator = BoundsIndicatorController()
    private lazy var cameraPreview = CameraPreviewController(coordinator: self)
    /// The recording folder (in "Recordings In Progress") until it becomes a project.
    private var bundleURL: URL?
    /// The folder being recorded into, while a recording is in progress.
    var recordingFolder: URL? { isRecording ? bundleURL : nil }
    private var endProblem: Error?
    private var activeSelection: RecordSelection?
    private var timer: Timer?
    private var workingTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    var onStateChange: (() -> Void)?

    init() {
        // The capture ended by itself: finish what was recorded and say so (`recovered-from-error`).
        let unexpectedStop: (Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.endProblem = error
                // A pause, resume or start still running ends first.
                for await phase in self.$phase.values where phase != .working && phase != .starting { break }
                await self.finish()
            }
        }
        recorder.onUnexpectedStop = unexpectedStop
        deviceRecorder.onUnexpectedStop = unexpectedStop
        externalDevices.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        preferences.$openRecentProjectsWithRecordingPicker
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // The source overlays dim with the current setting.
        preferences.$recordingAreaCover
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Keep auxiliary windows in sync with the state.
        objectWillChange
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncWindows() }
            .store(in: &cancellables)
    }

    var isRecording: Bool {
        switch phase {
        case .starting, .recording, .paused, .working, .finishing: return true
        default: return false
        }
    }

    /// The active recording is an iPhone/iPad.
    private var isDeviceRecording: Bool {
        if case .device = activeSelection { return true }
        return false
    }

    var isWorking: Bool { phase == .working || phase == .starting || phase == .finishing }

    var cameraID: String? {
        get { preferences.recordingCameraID }
        set { objectWillChange.send(); preferences.recordingCameraID = newValue }
    }

    var microphoneID: String? {
        get { preferences.recordingMicrophoneID }
        set {
            objectWillChange.send()
            preferences.recordingMicrophoneID = newValue
            microphoneLevel.monitor(deviceID: isPickerOpen ? newValue : nil)
        }
    }

    var systemAudio: Bool {
        get { preferences.recordingSystemAudio }
        set { objectWillChange.send(); preferences.recordingSystemAudio = newValue }
    }

    /// nil records every app; otherwise the selected apps' bundle IDs, kept while they are not running.
    var systemAudioApps: [String]? {
        get { preferences.recordingSystemAudioApps }
        set { objectWillChange.send(); preferences.recordingSystemAudioApps = newValue }
    }

    /// Adds or removes one app from the selection.
    func setSystemAudioApp(_ bundleID: String, on: Bool) {
        var apps = systemAudioApps ?? []
        if on, !apps.contains(bundleID) { apps.append(bundleID) }
        if !on { apps.removeAll { $0 == bundleID } }
        systemAudioApps = apps
    }

    /// An app that can be recorded (`capture.audioSources`: name, bundleId, appPath, processId).
    struct AudioSourceApp: Hashable {
        var name: String
        var bundleID: String
        var appPath: String
        var processID: pid_t
    }

    @Published private(set) var audioSourceApps: [AudioSourceApp] = []

    /// The apps with a normal window on screen (window layer 0), by name.
    func refreshAudioSourceApps() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let withWindows = Set(content.windows.filter { $0.windowLayer == 0 }.compactMap { $0.owningApplication?.processID })
        let apps = content.applications.filter { withWindows.contains($0.processID) }.compactMap { app -> AudioSourceApp? in
            guard !app.bundleIdentifier.isEmpty, let path = NSRunningApplication(processIdentifier: app.processID)?.bundleURL?.path else { return nil }
            return AudioSourceApp(name: app.applicationName, bundleID: app.bundleIdentifier, appPath: path, processID: app.processID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if apps != audioSourceApps { audioSourceApps = apps }
    }

    // MARK: Picker

    /// Opens the record picker, optionally preselecting a source type (global shortcuts/menus).
    func openPicker(preselect: SourceType? = nil) {
        guard !isRecording else { return }
        guard Permissions.canRecord else {
            OnboardingWindowController.shared.show()
            return
        }
        refreshDevices()
        RecordingRecovery.shared.refresh()
        // A chosen camera or microphone that is gone stays chosen: Start asks about it.
        isPickerOpen = true
        let sources = reloadSources()
        if pickerPanel == nil {
            pickerPanel = GlassPanel(height: 64, cornerRadius: 16, focusable: true, positionKey: "recording-picker") {
                RecordingPickerView(coordinator: self)
            }
        }
        pickerPanel?.present()
        pickerPanel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        microphoneLevel.monitor(deviceID: microphoneID)
        if let preselect {
            selectType(preselect)
            // What depends on the screens (a single display, the saved area) is chosen once they are known.
            Task {
                await sources.value
                if sourceType == preselect, selection == nil { autoSelect(preselect) }
            }
        }
        installPickerShortcuts()
    }

    /// 1, 2 and 3 pick display, window and area while the picker is open
    /// (`selectRecordDisplayInPicker`…).
    private func installPickerShortcuts() {
        guard pickerKeyMonitor == nil else { return }
        pickerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPickerOpen, case .idle = self.phase,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let types: [String: SourceType] = ["1": .display, "2": .window, "3": .area]
            guard let type = event.charactersIgnoringModifiers.flatMap({ types[$0] }) else { return event }
            if self.sourceType != type { self.selectType(type) }
            return nil
        }
    }

    func closePicker() {
        countdownTask?.cancel()
        if case .countdown = phase { phase = .idle }
        isPickerOpen = false
        sourceType = nil
        selection = nil
        pickerPanel?.orderOut(nil)
        if let pickerKeyMonitor { NSEvent.removeMonitor(pickerKeyMonitor) }
        pickerKeyMonitor = nil
        overlays.hide()
        microphoneLevel.stop()
        onStateChange?()
    }

    func refreshDevices() {
        cameras = DeviceCatalog.cameras()
        microphones = DeviceCatalog.microphones()
    }

    private var sourcesRefresh: Task<Void, Never>?

    /// One refresh of the screen sources at a time: a refresh asked for while one runs joins it.
    @discardableResult
    private func reloadSources() -> Task<Void, Never> {
        if let sourcesRefresh { return sourcesRefresh }
        let task = Task {
            await refreshSources()
            sourcesRefresh = nil
        }
        sourcesRefresh = task
        return task
    }

    func refreshSources() async {
        do {
            let sources = try await CaptureCatalog.sources()
            displays = sources.displays
            windows = sources.windows
        } catch {
            Dialogs.info(
                title: "Regrava Studio does not have permission to record your screen",
                message: "Please check your system privacy settings."
            )
        }
    }

    /// Source button click: toggles the type; a single display is selected immediately.
    func selectType(_ type: SourceType) {
        if sourceType == type {
            sourceType = nil
            selection = nil
            return
        }
        sourceType = type
        selection = nil
        autoSelect(type)
        if type == .device { return }
        reloadSources()
    }

    /// A single display is selected right away; Area starts from the last picked area.
    private func autoSelect(_ type: SourceType) {
        switch type {
        case .display:
            if displays.count == 1 { selection = .display(displays[0]) }
        case .area:
            if let saved = preferences.lastPickedArea, displays.contains(where: { $0.id == saved.displayID }) {
                selection = .area(displayID: saved.displayID, rect: saved.rect)
            }
        case .window, .device:
            break
        }
    }

    /// Escape: clears the selected source, else closes the picker.
    func escape() {
        if case .countdown = phase {
            cancelCountdown()
        } else if sourceType != nil {
            sourceType = nil
            selection = nil
        } else {
            closePicker()
        }
    }

    /// The picker's close button: cancels a countdown, else closes the picker (with a source
    /// still chosen).
    func closeButtonPressed() {
        if case .countdown = phase {
            cancelCountdown()
        } else {
            closePicker()
        }
    }

    func toggleWindow(_ window: WindowInfo) {
        selection = selection == .window(window) ? nil : .window(window)
    }

    func setArea(displayID: CGDirectDisplayID, rect: CGRect) {
        selection = .area(displayID: displayID, rect: rect)
        preferences.lastPickedArea = PickedArea(displayID: displayID, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// "Adjust recording area": switch to Area with the window's bounds.
    func adjustArea(to window: WindowInfo) {
        guard let display = displays.first(where: { $0.frame.intersects(window.frame) }) else { return }
        sourceType = .area
        let local = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: display.frame.size))
        setArea(displayID: display.id, rect: local)
    }

    /// Escape in the source overlays closes this first (the window's custom size fields).
    var overlayEscapeOverride: (() -> Void)?

    /// After a window was resized: the list, and the picked window, take its new bounds.
    func windowResized(_ window: WindowInfo) {
        Task {
            await refreshSources()
            if case .window(let picked) = selection, picked.id == window.id,
               let updated = windows.first(where: { $0.id == window.id }) {
                selection = .window(updated)
            }
        }
    }

    /// A window chosen from "Select window".
    func selectWindow(_ window: WindowInfo) {
        sourceType = .window
        selection = .window(window)
    }

    /// "Record entire display" from the window picker.
    func recordEntireDisplay(_ display: DisplayInfo) {
        sourceType = .display
        selection = .display(display)
    }

    /// "Choose a device" from the device menu: shows the device overlay (`screen = {type: "device"}`).
    func selectDevice(_ device: ExternalDevice) {
        sourceType = .device
        selection = .device(id: device.deviceId)
    }

    /// The selected device, while it is still connected.
    var selectedDevice: ExternalDevice? {
        guard case .device(let id) = selection else { return nil }
        return externalDevices.devices.first { $0.deviceId == id }
    }

    var selectionError: String? {
        guard let selection else { return "Choose what to record" }
        if case .device = selection, selectedDevice?.availability != .available { return "Device not found - make sure it is still connected" }
        if case let .area(_, rect) = selection, rect.width < Self.minimumAreaSize || rect.height < Self.minimumAreaSize {
            return "Minimal size is 150×150px."
        }
        return nil
    }

    // MARK: Start

    /// Start button (overlay) or Enter; a card's button records its own display or window.
    func startPressed(target: RecordSelection? = nil) {
        if let target {
            switch target {
            case .display: sourceType = .display
            case .window: sourceType = .window
            case .area: sourceType = .area
            case .device: sourceType = .device
            }
            selection = target
        }
        guard let selection, selectionError == nil, !isRecording else { return }
        Task {
            // Missing access is asked for first; Start is then pressed again.
            if microphoneID != nil, !MediaPermission.microphone.isAuthorized {
                MediaPermission.microphone.request()
                return
            }
            if cameraID != nil, !MediaPermission.camera.isAuthorized {
                MediaPermission.camera.request()
                return
            }
            guard let resolved = await resolveStart(selection) else { return }
            self.selection = resolved.selection
            startDevices = resolved.devices
            if let duration = preferences.recordingCountdownDuration, duration > 0 {
                overlays.hide()
                phase = .countdown(total: duration, startedAt: Date())
                countdownTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                    if !Task.isCancelled, case .countdown = self.phase { await self.begin() }
                }
            } else {
                await begin()
            }
        }
    }

    /// The camera and microphone the recording uses: the chosen ones that are connected.
    private var startDevices: (cameraID: String?, microphoneID: String?) = (nil, nil)

    /// Asked once until the device is chosen again.
    private static let previousCameraNotConnectedKey = "showInfoAboutPreviousCameraNotConnected"
    private static let previousMicrophoneNotConnectedKey = "showInfoAboutPreviousMicrophoneNotConnected"

    private func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// The checks before a recording starts, in order; nil when one stops it.
    private func resolveStart(_ selection: RecordSelection) async -> (selection: RecordSelection, devices: (cameraID: String?, microphoneID: String?))? {
        refreshDevices()
        let microphone = microphoneID.flatMap { id in microphones.first { $0.id == id } }
        let camera = cameraID.flatMap { id in cameras.first { $0.id == id } }
        func permissionDialog(_ title: String, _ permission: MediaPermission) {
            Dialogs.messageBox(
                title: title,
                message: "Please check your system privacy settings.",
                buttons: [("Open System Settings", { permission.request() }), ("Close", {})]
            )
        }
        if MediaPermission.screen.isDenied {
            permissionDialog("Regrava Studio does not have permission to record your screen", .screen)
            return nil
        }
        if let microphone, MicrophoneLid.mayHaveLidClosed(microphoneID: microphone.id) {
            Dialogs.info(
                title: "Microphone you selected is covered by laptop lid",
                message: "Please open the lid so the microphone can capture audio or select another microphone."
            )
            return nil
        }
        if microphone != nil {
            UserDefaults.standard.set(true, forKey: Self.previousMicrophoneNotConnectedKey)
            if MediaPermission.microphone.isDenied {
                permissionDialog("Regrava Studio does not have permission to use your microphone", .microphone)
                return nil
            }
        }
        if camera != nil {
            UserDefaults.standard.set(true, forKey: Self.previousCameraNotConnectedKey)
            if MediaPermission.camera.isDenied {
                permissionDialog("Regrava Studio does not have permission to use your camera", .camera)
                return nil
            }
        }
        if camera != nil, microphone == nil, !Dialogs.confirm(
            title: "Record muted camera?",
            message: "Seems you have selected a camera but no microphone. Do you want to continue recording with muted camera?",
            confirm: "Record muted camera"
        ) {
            return nil
        }
        if cameraID != nil, camera == nil, flag(Self.previousCameraNotConnectedKey) {
            guard Dialogs.confirm(
                title: "Camera you have previously selected seems to not be connected anymore",
                message: "Do you want to continue recording without camera?",
                confirm: "Record without camera"
            ) else { return nil }
            UserDefaults.standard.set(false, forKey: Self.previousCameraNotConnectedKey)
        }
        if microphoneID != nil, microphone == nil, flag(Self.previousMicrophoneNotConnectedKey) {
            guard Dialogs.confirm(
                title: "Microphone you have previously selected seems to not be connected anymore",
                message: "Do you want to continue recording without microphone?",
                confirm: "Record without microphone"
            ) else { return nil }
            UserDefaults.standard.set(false, forKey: Self.previousMicrophoneNotConnectedKey)
        }
        var selection = selection
        if case .window(let picked) = selection {
            // The window as it is now: gone, moved or resized since it was picked.
            guard var live = await CaptureCatalog.window(id: picked.id) else {
                Dialogs.info(
                    title: "Window is not capturable anymore",
                    message: "Window is not capturable anymore. Maybe it was closed. Please try again."
                )
                return nil
            }
            if live.frame == picked.frame { live = picked }
            selection = .window(live)
            WindowActions.bringToFront(live)
        }
        return (selection, (camera?.id, microphone?.id))
    }

    /// "Continue" in the get-ready indicator: start now.
    func continueCountdown() {
        countdownTask?.cancel()
        Task { await begin() }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        phase = .idle
    }

    private func begin() async {
        guard let selection else { return }
        phase = .starting
        bundleURL = nil
        activeSelection = selection
        overlays.hide()
        pickerPanel?.orderOut(nil)
        isPickerOpen = false
        if let pickerKeyMonitor { NSEvent.removeMonitor(pickerKeyMonitor) }
        pickerKeyMonitor = nil

        let bundle: URL
        do {
            bundle = try makeRecordingFolder()
        } catch {
            phase = .idle
            Dialogs.error("Failed to start recording (\(error.localizedDescription))")
            return
        }
        bundleURL = bundle
        endProblem = nil
        // Selected apps become the pids of every listed source with that bundle ID.
        var pids: [pid_t]?
        if systemAudio, let apps = systemAudioApps {
            await refreshAudioSourceApps()
            pids = Array(Set(audioSourceApps.filter { apps.contains($0.bundleID) }.map(\.processID)))
        }
        let options = CaptureOptions(
            fps: 60,
            capturesSystemAudio: systemAudio,
            systemAudioProcessIDs: pids,
            microphoneID: startDevices.microphoneID,
            hidesDesktopIcons: preferences.hideDesktopContentWhileRecording,
            cameraID: startDevices.cameraID,
            cameraMaxHeight: preferences.maximumWebcamHeight
        )
        // Device recordings always carry the device's audio.
        let recordsSound = options.capturesSystemAudio || options.microphoneID != nil || selection.captureSource == nil
        lastRecordsSound = recordsSound
        await RecordingSounds.playBegin(recordsSound: recordsSound)
        do {
            let work = bundle
            if let source = selection.captureSource {
                try await recorder.start(source: source, options: options, workDirectory: work)
            } else if let device = selectedDevice {
                try await deviceRecorder.start(device: device, options: options, workDirectory: work)
            } else {
                throw CaptureError.failed("Failed to find or connect to selected device")
            }
        } catch {
            phase = .idle
            try? FileManager.default.removeItem(at: bundle)
            microphoneLevel.stop()
            Dialogs.error("Failed to start recording (\(error.localizedDescription))")
            return
        }
        microphoneLevel.stop()
        phase = .recording
        if preferences.hideAppDockIconWhileRecording { NSApp.setActivationPolicy(.accessory) }
        startTimer()
        onStateChange?()
    }

    private func makeRecordingFolder() throws -> URL {
        let name: String
        let mode: String
        switch selection {
        case .display(let display): name = display.label; mode = "display"
        case .window(let window): name = window.appName.replacingOccurrences(of: ".app", with: ""); mode = "window"
        case .device: name = "External Device"; mode = "device"
        default: name = "Area"; mode = "display"
        }
        return try RecordingFolders.makeFolder(name: name, mode: mode)
    }

    // MARK: Recording actions

    /// Whether the current recording captures sound (the start sound then waits before capture).
    private var lastRecordsSound = false

    func pause() {
        guard phase == .recording else { return }
        run { try await self.isDeviceRecording ? self.deviceRecorder.pause() : self.recorder.pause() } then: {
            self.phase = .paused
            RecordingSounds.playEnd()
        }
    }

    func resume() {
        guard phase == .paused else { return }
        run {
            await RecordingSounds.playBegin(recordsSound: self.lastRecordsSound)
            try await self.isDeviceRecording ? self.deviceRecorder.resume() : self.recorder.resume()
        } then: { self.phase = .recording }
    }

    func togglePause() {
        phase == .paused ? resume() : pause()
    }

    func addMarker() {
        guard phase == .recording else { return }
        if isDeviceRecording { deviceRecorder.addMarker() } else { recorder.addMarker() }
        flagFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.flagFlash = false
        }
    }

    func requestCancel() {
        guard isRecording, !isWorking else { return }
        guard Dialogs.confirm(
            title: "Discard this recording?",
            message: "Everything recorded so far will be deleted.",
            confirm: "Discard",
            cancel: "Continue Recording",
            destructive: true
        ) else { return }
        Task {
            if isDeviceRecording { await deviceRecorder.cancel() } else { await recorder.cancel() }
            if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) }
            endRecordingUI()
        }
    }

    func requestRestart() {
        guard isRecording, !isWorking, let selection = activeSelection else { return }
        guard Dialogs.confirm(
            title: "Restart this recording?",
            message: "Everything recorded so far will be deleted, and a new recording will start.",
            confirm: "Restart",
            cancel: "Continue Recording",
            destructive: true
        ) else { return }
        Task {
            if isDeviceRecording { await deviceRecorder.cancel() } else { await recorder.cancel() }
            if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) }
            stopTimer()
            self.selection = selection
            await begin()
        }
    }

    /// "Finish recording": finalizes the folder, makes the project and runs the after-recording
    /// action; the three outcomes of `finishAndCreateProject`.
    func finish() async {
        guard phase == .recording || phase == .paused, let folder = bundleURL else { return }
        phase = .finishing
        scheduleWorkingIndicator()
        let problem = endProblem
        endProblem = nil
        var made: (bundle: URL, project: Project)?
        var failure: Error?
        do {
            let output = folder.appendingPathComponent(RecordingFinalizer.videoFileName)
            let result = try await isDeviceRecording ? deviceRecorder.finish(to: output) : recorder.finish(to: output)
            RecordingSounds.playEnd()
            made = try RecordingFolders.createProject(from: result, folder: folder)
        } catch {
            failure = error
        }
        endRecordingUI()
        RecordingRecovery.shared.refresh()
        guard let made else {
            // `finalization-failed`: the folder keeps the recording for recovery.
            let message = "The recording finished, but could not be fully finalized (usually a disk-space problem). Your footage is safe. Free up some disk space, then recover it now - or later via File → Recover recording. (\(failure?.localizedDescription ?? ""))"
            if Dialogs.confirm(title: "Recording needs to be recovered", message: message, confirm: "Recover now", cancel: "Later") {
                await RecordingRecovery.shared.recover(folder)
            }
            return
        }
        if problem != nil {
            Dialogs.info(title: "Recording successfully recovered after error", message: "The capture hit an error mid-recording, but your footage was recovered and will open now.")
            AppController.shared.openProject(bundle: made.bundle, project: made.project, isNewRecording: true)
        } else {
            AppController.shared.openProject(bundle: made.bundle, project: made.project, afterRecording: preferences.actionAfterRecording, isNewRecording: true)
        }
    }

    func requestFinish() {
        Task { await finish() }
    }

    private func endRecordingUI() {
        stopTimer()
        phase = .idle
        activeSelection = nil
        selection = nil
        sourceType = nil
        showsWorking = false
        if preferences.hideAppDockIconWhileRecording { AppController.shared.applyDockIconPolicy() }
        onStateChange?()
    }

    private func run(_ operation: @escaping () async throws -> Void, then: @escaping () -> Void) {
        let previous = phase
        phase = .working
        scheduleWorkingIndicator()
        Task {
            do {
                try await operation()
                then()
            } catch {
                phase = previous
                Dialogs.error(error.localizedDescription)
            }
            showsWorking = false
            workingTask?.cancel()
        }
    }

    private func scheduleWorkingIndicator() {
        workingTask?.cancel()
        workingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled && self.isWorking { self.showsWorking = true }
        }
    }

    private func startTimer() {
        clock.elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.elapsed = self.isDeviceRecording ? self.deviceRecorder.elapsed : self.recorder.elapsed
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        clock.elapsed = 0
    }

    // MARK: Device permissions

    /// The camera and microphone in use by the open picker, as last checked.
    private var checkedCameraID: String?
    private var checkedMicrophoneID: String?

    /// Whenever the picker's camera or microphone changes to one the app may not use, says so.
    private func verifySelectedDevicePermissions() {
        let camera = isPickerOpen ? cameras.first { $0.id == cameraID }?.id : nil
        let microphone = isPickerOpen ? microphones.first { $0.id == microphoneID }?.id : nil
        if camera != checkedCameraID {
            checkedCameraID = camera
            if camera != nil, MediaPermission.camera.isDenied {
                DispatchQueue.main.async {
                    Dialogs.messageBox(
                        title: "Regrava Studio does not have permission to use your webcam",
                        message: "You selected a webcam, but Regrava Studio does not have permission to use it. Please check your system privacy settings.",
                        buttons: [("Open System Settings", { MediaPermission.camera.request() }), ("Cancel", {})]
                    )
                }
            }
        }
        if microphone != checkedMicrophoneID {
            checkedMicrophoneID = microphone
            if microphone != nil, MediaPermission.microphone.isDenied {
                DispatchQueue.main.async {
                    Dialogs.messageBox(
                        title: "Regrava Studio does not have permission to use your microphone",
                        message: "You selected a microphone, but Regrava Studio does not have permission to use it. Please check your system privacy settings.",
                        buttons: [("Open System Settings", { MediaPermission.microphone.request() }), ("Cancel", {})]
                    )
                }
            }
        }
    }

    // MARK: Auxiliary windows

    private func syncWindows() {
        // Source overlays while choosing a display / window / area, or the device overlay.
        if isPickerOpen, sourceType != nil, !isRecording {
            if case .countdown = phase { overlays.hide() } else { overlays.show() }
        } else {
            overlays.hide()
        }

        // Recent projects, beside the picker while no source is chosen.
        if isPickerOpen, sourceType == nil, !isRecording, preferences.openRecentProjectsWithRecordingPicker,
           !AppController.shared.recentProjects.isEmpty {
            if recentProjectsPanel == nil {
                recentProjectsPanel = RecentProjectsPanel { [weak self] in
                    // The close button turns the setting off.
                    self?.preferences.openRecentProjectsWithRecordingPicker = false
                    self?.objectWillChange.send()
                }
            }
            recentProjectsPanel?.present()
        } else {
            recentProjectsPanel?.orderOut(nil)
        }

        // Recording widget.
        if isRecording && preferences.showRecordingWidget {
            if widgetPanel == nil {
                widgetPanel = GlassPanel(height: 48, cornerRadius: 11, focusable: false, positionKey: "recording-manager") {
                    RecordingWidgetView(coordinator: self)
                }
            }
            if widgetPanel?.isVisible == false { widgetPanel?.present() }
        } else {
            widgetPanel?.orderOut(nil)
        }

        // Dim what is not recorded.
        if isRecording, let selection = activeSelection, selection.globalBounds != nil {
            boundsIndicator.show(selection: selection, cover: preferences.recordingAreaCover)
        } else {
            boundsIndicator.hide()
        }

        verifySelectedDevicePermissions()

        // Camera preview.
        if showCameraPreview, let cameraID, isPickerOpen || isRecording {
            cameraPreview.show(cameraID: cameraID)
        } else {
            cameraPreview.hide()
        }
        // A hidden picker is fitted again when it is presented.
        if pickerPanel?.isVisible == true { pickerPanel?.refit() }
    }
}

/// Elapsed recording time, apart from the coordinator so its ticks redraw only the timer.
@MainActor
final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}
