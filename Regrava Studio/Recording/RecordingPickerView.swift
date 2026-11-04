import AVFoundation
import AppKit
import RegravaCapture
import SwiftUI

/// Record picker row.
struct RecordingPickerView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject private var recovery = RecordingRecovery.shared

    var body: some View {
        HStack(spacing: Theme.gap(1)) {
            PanelIconButton(icon: "xmark.circle.fill", size: 50, iconSize: 20) { coordinator.closeButtonPressed() }
            PanelDivider(verticalMargin: 10)
            // Only while there is something to recover.
            if !recovery.unfinished.isEmpty {
                RSButton(title: recovery.actionName, icon: "arrow.up.circle", kind: .transparent, size: .big) {
                    coordinator.closePicker()
                    Task { await RecordingRecovery.shared.recoverAll() }
                }
                .fixedSize()
                PanelDivider(verticalMargin: 10)
            }
            if case let .countdown(total, startedAt) = coordinator.phase {
                CountdownIndicator(total: total, startedAt: startedAt) { coordinator.continueCountdown() }
            } else {
                inputRow
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(minWidth: 500)
        .frame(height: 64)
        .foregroundStyle(Theme.Colors.text)
        .onExitCommand { coordinator.escape() }
    }

    private var inputRow: some View {
        HStack(spacing: Theme.gap(1)) {
            HStack(spacing: Theme.gap(0)) {
                ForEach(SourceType.allCases, id: \.self) { type in
                    SourceButton(type: type, isActive: coordinator.sourceType == type, contextMenu: contextMenu(for: type)) {
                        if type == .device {
                            DeviceSourceMenu.show(coordinator: coordinator)
                        } else {
                            coordinator.selectType(type)
                        }
                    }
                }
            }
            PanelDivider(verticalMargin: 10)
            HStack(spacing: Theme.gap(0)) {
                CameraButton(coordinator: coordinator)
                MicrophoneButton(coordinator: coordinator, monitor: coordinator.microphoneLevel)
                SystemAudioButton(coordinator: coordinator)
            }
            PanelDivider(verticalMargin: 10)
            RecentProjectsToggle(preferences: coordinator.preferences)
            RecordingOptionsButton(coordinator: coordinator)
        }
    }
}

extension RecordingPickerView {
    /// Right click on Display lists the displays; on Window, the windows to pick from.
    private func contextMenu(for type: SourceType) -> (() -> MenuBuilder?)? {
        let coordinator = self.coordinator
        switch type {
        case .display:
            return {
                let menu = MenuBuilder()
                for display in coordinator.displays {
                    menu.item(display.label) { coordinator.recordEntireDisplay(display) }
                }
                return menu
            }
        case .window:
            return {
                let menu = MenuBuilder()
                WindowSelectMenu.add(to: menu, coordinator: coordinator)
                return menu
            }
        case .area, .device:
            return nil
        }
    }
}

/// "Select window": one item per app, with a submenu of its windows when it has several;
/// the window being picked is checked.
@MainActor
enum WindowSelectMenu {
    static func add(to menu: MenuBuilder, coordinator: RecordingCoordinator) {
        var groups: [(appPath: String?, windows: [WindowInfo])] = []
        for window in coordinator.windows {
            if let index = groups.firstIndex(where: { $0.appPath == window.appPath }) {
                groups[index].windows.append(window)
            } else {
                groups.append((window.appPath, [window]))
            }
        }
        var current: CGWindowID?
        if coordinator.sourceType == .window, case .window(let window) = coordinator.selection { current = window.id }
        for group in groups {
            let first = group.windows[0]
            let image = first.appPath.map { FileIcons.icon(forFile: $0) }
            if group.windows.count == 1 {
                menu.item(first.appName, image: image, checked: first.id == current) { coordinator.selectWindow(first) }
            } else {
                menu.submenu(first.appName, image: image, checked: group.windows.contains { $0.id == current }) { sub in
                    for window in group.windows {
                        sub.item(window.title, checked: window.id == current) { coordinator.selectWindow(window) }
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

/// 1 px divider, `text@0.1`.
struct PanelDivider: View {
    var verticalMargin: CGFloat
    var opacity = 0.1

    var body: some View {
        Rectangle().fill(Color.white.opacity(opacity)).frame(width: 1).padding(.vertical, verticalMargin)
    }
}

/// Square icon button with hover background (close button: 50×50, radius 9, icon 20).
struct PanelIconButton: View {
    var icon: String
    var size: CGFloat
    var iconSize: CGFloat
    var tooltip: String?
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 9).fill(hovered ? Theme.Colors.hover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .tooltip(tooltip ?? "")
    }
}

/// Source button: 56×50, radius 9, icon 20, label 10 at 0.55; active icon wiggles.
private struct SourceButton: View {
    var type: SourceType
    var isActive: Bool
    var contextMenu: (() -> MenuBuilder?)?
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.gap(0.75)) {
                WiggleIcon(name: type.icon, size: 20, isWiggling: isActive)
                    .frame(width: 24, height: 22)
                Text(type.label)
                    .font(.system(size: 10))
                    .opacity(Theme.secondaryOpacity)
                    .padding(.bottom, -2)
            }
            .frame(width: 56, height: 50)
            .background(RoundedRectangle(cornerRadius: 9).fill(isActive || hovered ? Theme.Colors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .rightClickMenu { contextMenu?() }
    }
}

/// Icon that wiggles horizontally (x: 0,−2,2,−1,1,0 over 2 s, infinite).
struct WiggleIcon: View {
    var name: String
    var size: CGFloat
    var isWiggling: Bool

    var body: some View {
        TimelineView(.animation(paused: !isWiggling)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            Image(systemName: name)
                .font(.system(size: size))
                .offset(x: isWiggling ? Self.offset(t) : 0)
        }
    }

    static func offset(_ t: Double) -> CGFloat {
        let keys: [CGFloat] = [0, -2, 2, -1, 1, 0]
        let position = t * Double(keys.count - 1)
        let i = min(Int(position), keys.count - 2)
        let f = CGFloat(position - Double(i))
        let eased = f * f * (3 - 2 * f)
        return keys[i] + (keys[i + 1] - keys[i]) * eased
    }
}

/// Holds the NSView a SwiftUI control lives in, to anchor native menus below it.
final class AnchorHolder {
    weak var view: NSView?
}

struct MenuAnchor: NSViewRepresentable {
    let holder: AnchorHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// Device-style button: largeControl padding, radius 9, gap 8; dimmed when inactive.
private struct DeviceButton<Accessory: View>: View {
    var icon: String
    var title: String
    var isActive: Bool
    var width: CGFloat?
    var tooltip: String?
    var action: (NSView?) -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovered = false
    private let anchor = AnchorHolder()

    var body: some View {
        Button { action(anchor.view) } label: {
            HStack(spacing: Theme.gap(1)) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 16)
                Text(title).font(Theme.Typo.controlCopy).lineLimit(1).truncationMode(.tail)
                if width != nil { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 14)
            .frame(width: width, alignment: .leading)
            .frame(height: 50)
            .opacity(isActive || hovered ? 1 : 0.5)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovered ? Theme.Colors.hover : .clear))
            .overlay(alignment: .bottom) { accessory() }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(MenuAnchor(holder: anchor))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .tooltip(tooltip ?? "")
        // A right click opens the same menu, at the mouse.
        .onRightClick { action(nil) }
    }
}

// MARK: - Camera

private struct CameraButton: View {
    @ObservedObject var coordinator: RecordingCoordinator

    private var selected: CaptureDeviceInfo? { coordinator.cameras.first { $0.id == coordinator.cameraID } }

    var body: some View {
        DeviceButton(
            icon: selected == nil ? "video.slash" : "video",
            title: selected?.name ?? "No camera",
            isActive: selected != nil,
            width: 126,
            action: showMenu
        ) { EmptyView() }
    }

    /// Opens without asking for the camera permission: choosing a camera checks it.
    private func showMenu(_ anchor: NSView?) {
        Task { @MainActor in
            coordinator.refreshDevices()
            let menu = MenuBuilder()
            menu.group("devices")
            for camera in coordinator.cameras {
                menu.item(camera.name, badge: camera.isDefault ? "Default" : nil, checked: camera.id == coordinator.cameraID) {
                    coordinator.cameraID = camera.id
                }
            }
            menu.item("Don't record camera", checked: coordinator.cameraID == nil) { coordinator.cameraID = nil }
            menu.group("options")
            menu.toggle("Show camera preview", isOn: coordinator.showCameraPreview) { coordinator.showCameraPreview = $0 }
            let heights = [720, 1080, 2160]
            menu.segmented(
                "Max resolution",
                options: ["720p", "1080p", "4K"],
                selected: heights.firstIndex(of: coordinator.preferences.maximumWebcamHeight) ?? 1
            ) { coordinator.preferences.maximumWebcamHeight = heights[$0] }
            menu.popUp(below: anchor)
        }
    }
}

// MARK: - Microphone

private struct MicrophoneButton: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var monitor: MicrophoneLevelMonitor

    private var selected: CaptureDeviceInfo? { coordinator.microphones.first { $0.id == coordinator.microphoneID } }

    var body: some View {
        DeviceButton(
            icon: selected == nil ? "microphone.slash.fill" : "microphone.fill",
            title: selected?.name ?? "No microphone",
            isActive: selected != nil,
            width: 146,
            action: showMenu
        ) {
            if selected != nil {
                ZStack(alignment: .trailing) {
                    LevelBar(level: monitor.level, peak: monitor.peak).frame(height: 3)
                    if monitor.isSilent {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.warning)
                            .offset(y: -8)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
            }
        }
    }

    private func showMenu(_ anchor: NSView?) {
        Task { @MainActor in
            guard await Permissions.ensureAccess(for: .audio) else {
                Dialogs.info(
                    title: "Microphone permission required",
                    message: "Please allow access to your microphone in order to record your voice."
                )
                return
            }
            coordinator.refreshDevices()
            let menu = MenuBuilder()
            menu.group("devices")
            for microphone in coordinator.microphones {
                menu.item(microphone.name, badge: microphone.isDefault ? "Default" : nil, checked: microphone.id == coordinator.microphoneID) {
                    coordinator.microphoneID = microphone.id
                }
                if microphone.id == coordinator.microphoneID { menu.level(monitor) }
            }
            menu.item("Don't record microphone", checked: coordinator.microphoneID == nil) { coordinator.microphoneID = nil }
            menu.popUp(below: anchor)
        }
    }
}

// MARK: - System audio

private struct SystemAudioButton: View {
    @ObservedObject var coordinator: RecordingCoordinator

    /// `Record system audio` / `Sound from N app|apps` (stored IDs) / `No system audio`.
    private var title: String {
        guard coordinator.systemAudio else { return "No system audio" }
        guard let apps = coordinator.systemAudioApps else { return "Record system audio" }
        return "Sound from \(apps.count) app\(apps.count == 1 ? "" : "s")"
    }

    var body: some View {
        DeviceButton(
            icon: "music.note.tv",
            title: title,
            isActive: coordinator.systemAudio,
            width: nil,
            action: showMenu
        ) { EmptyView() }
    }

    /// The toggles, then the apps, rebuilt in place as they change.
    private func showMenu(_ anchor: NSView?) {
        let coordinator = self.coordinator
        Task { @MainActor in
            await coordinator.refreshAudioSourceApps()
            let menu = MenuBuilder.live { menu in
                menu.group("system-audio")
                // On means every app, off means none (`"all"` / `null`).
                menu.toggle("Record system audio", isOn: coordinator.systemAudio) { on in
                    coordinator.systemAudio = on
                    coordinator.systemAudioApps = nil
                }
                guard coordinator.systemAudio else { return }
                let all = coordinator.systemAudioApps == nil
                menu.toggle("From all apps", isOn: all) { on in coordinator.systemAudioApps = on ? nil : [] }
                menu.group("apps")
                menu.header("Apps")
                for app in coordinator.audioSourceApps {
                    let selected = all || (coordinator.systemAudioApps?.contains(app.bundleID) ?? false)
                    menu.toggle(app.name, image: FileIcons.icon(forFile: app.appPath), isOn: selected, enabled: !all) { on in
                        coordinator.setSystemAudioApp(app.bundleID, on: on)
                    }
                }
            }
            // Apps that start or quit while the menu is open update it.
            let center = NSWorkspace.shared.notificationCenter
            let observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        await coordinator.refreshAudioSourceApps()
                        menu.refresh()
                    }
                }
            }
            menu.popUp(below: anchor)
            observers.forEach(center.removeObserver)
        }
    }
}

// MARK: - Right side

private struct RecentProjectsToggle: View {
    @ObservedObject var preferences: Preferences
    @State private var hovered = false

    var body: some View {
        Button {
            preferences.openRecentProjectsWithRecordingPicker.toggle()
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(height: 50)
                .opacity(preferences.openRecentProjectsWithRecordingPicker || hovered ? 1 : Theme.secondaryOpacity)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(preferences.openRecentProjectsWithRecordingPicker || hovered ? Theme.Colors.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .tooltip(preferences.openRecentProjectsWithRecordingPicker ? "Hide recent projects" : "Show recent projects")
    }
}

private struct RecordingOptionsButton: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @State private var hovered = false
    @State private var isMenuOpen = false
    private let anchor = AnchorHolder()

    var body: some View {
        Button(action: openMenu) {
            HStack(spacing: Theme.gap(0)) {
                Image(systemName: "gear").font(.system(size: 16))
                Image(systemName: "chevron.down").font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .opacity(hovered || isMenuOpen ? 1 : Theme.secondaryOpacity)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovered || isMenuOpen ? Theme.Colors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(MenuAnchor(holder: anchor))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .tooltip("Recording options")
    }

    /// Shows the button as active, then opens the (modal) menu on the next run-loop turn.
    private func openMenu() {
        isMenuOpen = true
        DispatchQueue.main.async {
            buildMenu().popUp(below: anchor.view)
            isMenuOpen = false
        }
    }

    private func buildMenu() -> MenuBuilder {
        let preferences = coordinator.preferences
        let menu = MenuBuilder()
        menu.group("before")
        menu.header("Before Recording")
        let durations: [Int?] = [nil, 3, 5, 10]
        menu.segmented(
            "Countdown",
            options: ["Off", "3s", "5s", "10s"],
            selected: durations.firstIndex(of: preferences.recordingCountdownDuration) ?? 0
        ) { preferences.recordingCountdownDuration = durations[$0] }
        menu.group("while")
        menu.header("While Recording")
        menu.toggle("Hide Desktop Icons", isOn: preferences.hideDesktopContentWhileRecording) { preferences.hideDesktopContentWhileRecording = $0 }
        menu.toggle("Hide Dock Icon", isOn: preferences.hideAppDockIconWhileRecording) { preferences.hideAppDockIconWhileRecording = $0 }
        menu.toggle("Highlight Recorded Area", isOn: preferences.recordingAreaCover) { preferences.recordingAreaCover = $0 }
        menu.toggle("Show Speaker Notes", isOn: preferences.showSpeakerNotes) { preferences.showSpeakerNotes = $0 }
        menu.group("after")
        menu.header("After Recording")
        menu.toggle("Open Quick Share Widget", isOn: preferences.showQuickExportWidget) { preferences.showQuickExportWidget = $0 }
        menu.group("advanced")
        menu.submenu("Advanced") { sub in
            sub.header("Recording Engine")
            sub.item("Use Modern Engine If Available", checked: preferences.recordingEngine == "auto") { preferences.recordingEngine = "auto" }
            sub.item("Force Modern Engine", checked: preferences.recordingEngine == "modern") { preferences.recordingEngine = "modern" }
            // Only ScreenCaptureKit is implemented in this app.
            sub.item("Force Legacy Engine", enabled: false)
        }
        menu.group("settings")
        menu.item("Settings…", shortcut: .make(",", keyCode: 43, "⌘")) { SettingsWindowController.shared.show() }
        return menu
    }
}

// MARK: - Device

/// iPhone/iPad source: the camera permission first, then the connected devices; choosing
/// one shows the device overlay.
@MainActor
enum DeviceSourceMenu {
    static let guideURL = URL(string: "https://regrava.studio/guide/recording-iphone-ipad")!
    private static let permissionMessage = "Regrava Studio needs camera recording permission to record external devices connected to your Mac"

    static func show(coordinator: RecordingCoordinator) {
        coordinator.selection = nil
        guard ensureCameraPermission() else { return }
        let devices = coordinator.externalDevices.devices
        let menu = MenuBuilder()
        if devices.isEmpty {
            menu.group("iOS")
            menu.disabled("No USB connected iOS devices")
            menu.group("iPadOS")
            menu.disabled("No USB connected iPadOS devices")
        } else {
            menu.group("devices")
            for device in devices {
                menu.item(device.menuLabel) { coordinator.selectDevice(device) }
            }
        }
        menu.group("howTo")
        menu.item("How to record iOS or iPadOS device?") { NSWorkspace.shared.open(guideURL) }
        menu.popUp(below: nil)
    }

    /// External devices are capture devices, so they need the Camera permission.
    private static func ensureCameraPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            Dialogs.info(title: "Regrava Studio will ask for camera recording permission", message: permissionMessage, button: "Continue")
            AVCaptureDevice.requestAccess(for: .video) { _ in }
            return false
        default:
            Dialogs.info(title: "No camera recording permission", message: permissionMessage + ". \n\n Please enable it in System Preferences > Security & Privacy > Camera.")
            return false
        }
    }
}

// MARK: - Countdown

/// "Get ready. Recording will start soon." + "Continue" with a countdown ring.
private struct CountdownIndicator: View {
    var total: Int
    var startedAt: Date
    var onContinue: () -> Void

    var body: some View {
        HStack(spacing: Theme.gap(1)) {
            Text("Get ready. Recording will start soon.")
                .font(.system(size: 13))
                .opacity(Theme.secondaryOpacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
            PanelDivider(verticalMargin: 10)
            Button(action: onContinue) {
                HStack(spacing: Theme.gap(1)) {
                    Text("Continue")
                    TimelineView(.animation) { context in
                        let elapsed = context.date.timeIntervalSince(startedAt)
                        let remaining = max(Double(total) - elapsed, 0)
                        ZStack {
                            Circle().stroke(Theme.Colors.recordingRed.opacity(0.2), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: remaining / Double(total))
                                .stroke(Theme.Colors.recordingRed, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            if remaining < 9 {
                                Text("\(Int(remaining.rounded(.up)))").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            }
                        }
                        .frame(width: 20, height: 20)
                    }
                }
                .font(Theme.Typo.controlCopy)
                .foregroundStyle(Theme.Colors.recordingRed)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.hover))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}
