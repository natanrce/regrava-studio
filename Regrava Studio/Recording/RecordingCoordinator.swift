import AVFoundation
import AppKit
import Combine
import RegravaCapture
import RegravaCore
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

    /// Global (Quartz, top-left origin) bounds of what is recorded.
    var globalBounds: CGRect {
        switch self {
        case .display(let display): return display.frame
        case .window(let window): return window.frame
        case let .area(id, rect):
            let origin = CGDisplayBounds(id).origin
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    var captureSource: CaptureSource {
        switch self {
        case .display(let display): return .display(display.id)
        case .window(let window): return .window(window.id)
        case let .area(id, rect): return .area(displayID: id, rect: rect)
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
    @Published private(set) var elapsed: TimeInterval = 0
    /// True while an operation has been running for ≥ 3 s ("Working...").
    @Published private(set) var showsWorking = false
    @Published private(set) var flagFlash = false

    let preferences = Preferences.shared
    let microphoneLevel = MicrophoneLevelMonitor()
    private let recorder = ScreenRecorder()
    private var pickerPanel: GlassPanel<RecordingPickerView>?
    private var widgetPanel: GlassPanel<RecordingWidgetView>?
    private lazy var overlays = SourceOverlayController(coordinator: self)
    private lazy var boundsIndicator = BoundsIndicatorController()
    private lazy var cameraPreview = CameraPreviewController(coordinator: self)
    private var bundleURL: URL?
    private var activeSelection: RecordSelection?
    private var timer: Timer?
    private var workingTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    var onStateChange: (() -> Void)?

    init() {
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                Dialogs.error("The recording stopped unexpectedly (\(error.localizedDescription)).")
                await self?.finish()
            }
        }
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

    // MARK: Picker

    /// Opens the record picker, optionally preselecting a source type (global shortcuts/menus).
    func openPicker(preselect: SourceType? = nil) {
        guard !isRecording else { return }
        guard Permissions.canRecord else {
            OnboardingWindowController.shared.show()
            return
        }
        refreshDevices()
        // Forget devices that are gone.
        if let id = cameraID, !cameras.contains(where: { $0.id == id }) { cameraID = nil }
        if let id = microphoneID, !microphones.contains(where: { $0.id == id }) { microphoneID = nil }
        isPickerOpen = true
        Task { await refreshSources() }
        if pickerPanel == nil {
            pickerPanel = GlassPanel(height: 64, cornerRadius: 16, focusable: true, positionKey: "recording-picker") {
                RecordingPickerView(coordinator: self)
            }
        }
        pickerPanel?.present()
        pickerPanel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        microphoneLevel.monitor(deviceID: microphoneID)
        if let preselect { selectType(preselect) }
    }

    func closePicker() {
        countdownTask?.cancel()
        if case .countdown = phase { phase = .idle }
        isPickerOpen = false
        sourceType = nil
        selection = nil
        pickerPanel?.orderOut(nil)
        overlays.hide()
        microphoneLevel.stop()
        onStateChange?()
    }

    func refreshDevices() {
        cameras = DeviceCatalog.cameras()
        microphones = DeviceCatalog.microphones()
    }

    func refreshSources() async {
        do {
            displays = try await CaptureCatalog.displays()
            windows = try await CaptureCatalog.windows()
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
        Task { await refreshSources() }
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

    func toggleDisplay(_ display: DisplayInfo) {
        selection = selection == .display(display) ? nil : .display(display)
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

    /// "Record entire display" from the window picker.
    func recordEntireDisplay(_ display: DisplayInfo) {
        sourceType = .display
        selection = .display(display)
    }

    var selectionError: String? {
        guard let selection else { return "Choose what to record" }
        if case let .area(_, rect) = selection, rect.width < Self.minimumAreaSize || rect.height < Self.minimumAreaSize {
            return "Minimal size is 150×150px."
        }
        return nil
    }

    // MARK: Start

    /// Start button (overlay) or Enter.
    func startPressed() {
        guard selection != nil, selectionError == nil, !isRecording else { return }
        Task {
            if microphoneID != nil, !(await Permissions.ensureAccess(for: .audio)) {
                Dialogs.info(
                    title: "Regrava Studio does not have permission to use your microphone",
                    message: "Please check your system privacy settings."
                )
                return
            }
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
        activeSelection = selection
        overlays.hide()
        pickerPanel?.orderOut(nil)
        isPickerOpen = false

        let bundle = makeBundleURL()
        bundleURL = bundle
        let options = CaptureOptions(
            fps: 60,
            capturesSystemAudio: systemAudio,
            microphoneID: microphoneID,
            hidesDesktopIcons: preferences.hideDesktopContentWhileRecording
        )
        if case .window(let window) = selection {
            NSRunningApplication(processIdentifier: window.processID)?.activate()
        }
        do {
            try await recorder.start(source: selection.captureSource, options: options, workDirectory: bundle.appendingPathComponent("segments", isDirectory: true))
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

    private func makeBundleURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name: String
        switch selection {
        case .display(let display): name = display.label
        case .window(let window): name = window.appName
        default: name = "Area"
        }
        return preferences.projectsFolder
            .appendingPathComponent("\(name) \(formatter.string(from: Date())).\(ProjectStore.fileExtension)", isDirectory: true)
    }

    // MARK: Recording actions

    func pause() {
        guard phase == .recording else { return }
        run { try await self.recorder.pause() } then: { self.phase = .paused }
    }

    func resume() {
        guard phase == .paused else { return }
        run { try await self.recorder.resume() } then: { self.phase = .recording }
    }

    func togglePause() {
        phase == .paused ? resume() : pause()
    }

    func addMarker() {
        guard phase == .recording else { return }
        recorder.addMarker()
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
            await recorder.cancel()
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
            await recorder.cancel()
            if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) }
            stopTimer()
            self.selection = selection
            await begin()
        }
    }

    /// "Finish recording": joins segments, creates the project and runs the after-recording action.
    func finish() async {
        guard phase == .recording || phase == .paused, let bundleURL else { return }
        phase = .finishing
        scheduleWorkingIndicator()
        do {
            let result = try await recorder.finish(to: bundleURL.appendingPathComponent("recording.mov"))
            try? FileManager.default.removeItem(at: bundleURL.appendingPathComponent("segments", isDirectory: true))
            var cursors: [RecordedCursor] = []
            for image in result.customCursors {
                let url = ProjectStore.cursorImageURL(bundle: bundleURL, id: image.id)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? image.pngData.write(to: url)) != nil else { continue }
                cursors.append(RecordedCursor(id: image.id, hotSpot: image.hotSpot, standardSize: image.size))
            }
            var project = Project(
                recording: RecordingInfo(
                    videoFileName: result.videoURL.lastPathComponent,
                    videoSize: result.videoSize,
                    pointPixelScale: result.pointPixelScale,
                    durationMs: result.durationMs,
                    fps: result.fps,
                    cursors: cursors,
                    audioSources: result.audioSources
                ),
                mouseEvents: result.mouseEvents,
                markersMs: result.markersMs,
                keystrokes: result.keystrokes
            )
            project.autoZoom.isEnabled = preferences.createAutomaticZooms
            project.regenerateAutomaticZooms()
            try ProjectStore.save(project, to: bundleURL)
            endRecordingUI()
            AppController.shared.openProject(bundle: bundleURL, project: project, afterRecording: preferences.actionAfterRecording)
        } catch {
            endRecordingUI()
            Dialogs.error("Failed to finish recording (\(error.localizedDescription))")
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
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = self.recorder.elapsed
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }

    // MARK: Auxiliary windows

    private func syncWindows() {
        // Source overlays while choosing a display / window / area.
        if isPickerOpen, let type = sourceType, type != .device, !isRecording {
            if case .countdown = phase { overlays.hide() } else { overlays.show() }
        } else {
            overlays.hide()
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
        if isRecording, let selection = activeSelection {
            boundsIndicator.show(selection: selection, cover: preferences.recordingAreaCover)
        } else {
            boundsIndicator.hide()
        }

        // Camera preview.
        if showCameraPreview, let cameraID, isPickerOpen || isRecording {
            cameraPreview.show(cameraID: cameraID)
        } else {
            cameraPreview.hide()
        }
        pickerPanel?.refit()
    }
}
