import AppKit
import Combine
import RegravaCore
import SwiftUI

/// Settings window content.
///
/// Omitted on purpose — they depend on online services: account dashboard, usage data, the
/// Advanced tab and the Dev tab.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, editing, widget, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .editing: return "Editing"
        case .widget: return "Quick export"
        case .shortcuts: return "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .editing: return "pencil.tip.crop.circle"
        case .widget: return "square.and.arrow.up"
        case .shortcuts: return "command.circle"
        }
    }
}

@MainActor
final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            VStack(alignment: .leading, spacing: Theme.gap(3)) {
                switch state.tab {
                case .general: GeneralSettings(preferences: preferences)
                case .recording: RecordingSettings(preferences: preferences)
                case .editing: EditingSettings(preferences: preferences)
                case .widget: QuickExportSettings(preferences: preferences)
                case .shortcuts: ShortcutsSettings(preferences: preferences)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 840)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.Colors.background)
        .foregroundStyle(Theme.Colors.text)
        .environment(\.colorScheme, .dark)
    }

    /// Tab bar: 4px gap, padding 10×40, lighterBg, 1px bottom border.
    private var tabBar: some View {
        HStack(spacing: Theme.gap(0)) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabItem(tab: tab, isActive: state.tab == tab) { state.tab = tab }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.lighterBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.systemBorder.opacity(0.5)).frame(height: 1) }
    }
}

private struct SettingsTabItem: View {
    var tab: SettingsTab
    var isActive: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.gap(1)) {
                Image(systemName: tab.icon).font(.system(size: Theme.Typo.controlIconSize)).frame(height: 20)
                Text(tab.title)
                    .font(Theme.Typo.label)
                    .opacity(Theme.secondaryOpacity)
                    .lineLimit(1)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(isActive || hovered ? Theme.Colors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Vertical stack with 32px gap and 1px separators between groups.
private struct SettingsGroups: View {
    var groups: [AnyView]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 { RSSeparator() }
                groups[index]
            }
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        SettingsGroups(groups: [
            AnyView(VStack(alignment: .leading, spacing: Theme.gap(3)) {
                ToggleRow(
                    title: "Start Regrava Studio at login",
                    description: "Automatically start Regrava Studio when starting your computer.",
                    isOn: Binding(get: { preferences.startAtStartup }, set: {
                        preferences.startAtStartup = $0
                        preferences.applyStartAtLogin()
                    })
                )
                ToggleRow(
                    title: "Hide Dock Icon",
                    richDescription: Text("Will hide the Dock icon when there are no opened projects and no recordings in progress. You can still access Regrava Studio from the menu bar ")
                        + Text(Image(systemName: "record.circle")) + Text(" icon."),
                    isOn: $preferences.hideDockIcon
                )
            }),
            AnyView(RSButton(title: "Reset preferences", kind: .dangerSubtle) {
                if Dialogs.confirm(
                    title: "Reset preferences",
                    message: "Are you sure you want to reset all preferences? This will include all your recording preferences.",
                    confirm: "Reset preferences",
                    destructive: true
                ) {
                    preferences.reset()
                }
            }),
        ])
    }
}

// MARK: Recording

private struct RecordingSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            FolderRow(
                title: "Save new projects to",
                path: preferences.projectsFolder.path,
                message: "Select a folder to save your projects"
            ) { preferences.projectsFolderPath = $0 }
            ToggleRow(
                title: "Highlight recorded area during recording",
                description: "When enabled, part of the screen not being recorded will be slightly dimmed.",
                isOn: $preferences.recordingAreaCover
            )
            ToggleRow(
                title: "Create zooms automatically",
                description: "When enabled, Regrava Studio will analyze your actions during the recording and create zooms automatically in every new project.",
                isOn: $preferences.createAutomaticZooms
            )
            ToggleRow(
                title: "Show recording widget",
                description: "When enabled, Regrava Studio will show a widget with the recording in progress status and controls.",
                isOn: $preferences.showRecordingWidget
            )
            NamedField(
                name: "Maximum camera resolution",
                description: "Max resolution at which your webcam will be recorded (if your webcam supports it).\n\nHigher resolutions improve video quality but may impact performance during recording.",
                horizontal: true
            ) {
                SegmentedPicker(
                    options: [720, 1080, 2160],
                    label: { $0 == 2160 ? "4K" : "\($0)p" },
                    selection: $preferences.maximumWebcamHeight
                )
            }
        }
    }
}

// MARK: Editing

private struct EditingSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            ToggleRow(
                title: "Use last project settings as default for new recordings",
                description: "When enabled, new recordings will be created with the same settings as the last project you edited. Note: If some of your presets is marked as default, it will be used instead.",
                isOn: $preferences.useLastProjectConfigForNewProjects
            )
            ToggleRow(
                title: "Use autosave",
                description: "When enabled, app will save your project changes automatically every 30 seconds.",
                isOn: $preferences.autoSaveProject
            )
            FolderRow(
                title: "Save presets in",
                path: preferences.presetsFolderPath ?? PresetStore.defaultFolder.path,
                message: "Select a folder to save your presets"
            ) { preferences.presetsFolderPath = $0 }
        }
    }
}

// MARK: Quick export

private struct QuickExportSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            NamedField(
                name: "Quick export settings",
                icon: "square.and.arrow.up",
                description: "These settings will be used when using quick export or exporting from the widget"
            ) {
                ExportSettingsForm(store: $preferences.widgetExportSettings, target: nil, aspectRatio: nil)
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.backgroundAccent))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
                    .padding(.top, 12)
            }
            ToggleRow(
                icon: "inset.filled.bottomleft.rectangle",
                title: "Show quick export widget after recording",
                description: "After the recording is done, a widget will appear that allows you to quickly export the recording. If disabled - full editor will be opened instead.",
                isOn: $preferences.showQuickExportWidget
            )
            ToggleRow(
                icon: "folder",
                title: "Always save project when using quick export widget",
                description: "If enabled, the project will be always saved after using the quick export widget. If disabled, You will be asked if you want to save or delete project.",
                isOn: $preferences.alwaysSaveProjectWhenUsingQuickExportWidget
            )
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var section = "recording"

    private struct Row {
        var action: ShortcutAction
        var title: String
        var icon: String
        var description: Text?
    }

    private let recordingGroups: [[Row]] = [
        [
            Row(action: .recordStartStop, title: "Start new Recording / Finish recording", icon: "record.circle",
                description: Text("This shortcut will open new recording picker from anywhere in the system and it will also stop current recording. Make sure it is not conflicting with other global shortcuts.")),
            Row(action: .pauseResume, title: "Resume/Pause recording in progress", icon: "playpause"),
            Row(action: .restartRecording, title: "Restart recording in progress", icon: "arrow.counterclockwise"),
            Row(action: .addRecordingMarker, title: "Create recording flag", icon: "flag",
                description: Text("Press this shortcut while recording to create a recording flag. Later, you will see moments marked with flags as ") + Text(Image(systemName: "flag")) + Text(" on the video timeline.")),
        ],
        [
            Row(action: .recordDisplay, title: "Record entire display", icon: "dock.rectangle"),
            Row(action: .recordWindow, title: "Record single window", icon: "macwindow"),
            Row(action: .recordArea, title: "Record area", icon: "square.dashed"),
        ],
        [
            Row(action: .toggleShowSpeakerNotes, title: "Show speaker notes", icon: "note.text"),
            Row(action: .toggleSpeakerNotesPrompter, title: "Start/Stop prompter in speaker notes", icon: "playpause"),
        ],
        [
            Row(action: .toggleRecordingWidget, title: "Show/Hide recording controls", icon: "rectangle.dashed.badge.record",
                description: Text("While recording is in progress, will show widget allowing you to finish, cancel or restart recording.")),
        ],
    ]

    private let editingGroups: [[Row]] = [
        [
            Row(action: .cutSlice, title: "Cut slice at current time", icon: "scissors"),
            Row(action: .removeSliceBeforeCut, title: "Remove slice before previous cut", icon: "scissors"),
        ],
        [
            Row(action: .playOrIncreaseSpeed, title: "Play or increase speed", icon: "play.circle"),
            Row(action: .playBackwardOrIncreaseSpeed, title: "Play backward or increase speed", icon: "play.circle.fill"),
            Row(action: .playOrPause, title: "Play or pause", icon: "playpause"),
        ],
    ]

    var body: some View {
        VStack(spacing: Theme.gap(3)) {
            SegmentedPicker(
                options: ["recording", "editing"],
                label: { $0 == "recording" ? "Recording" : "Editing" },
                icon: { $0 == "recording" ? "record.circle" : "play.circle" },
                selection: $section
            )
            .fixedSize()
            .frame(maxWidth: .infinity)
            let groups = section == "recording" ? recordingGroups : editingGroups
            VStack(alignment: .leading, spacing: Theme.gap(3)) {
                ForEach(groups.indices, id: \.self) { g in
                    VStack(alignment: .leading, spacing: Theme.gap(1)) {
                        ForEach(groups[g], id: \.action) { row in
                            HStack(spacing: Theme.gap(3)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: Theme.gap(1)) {
                                        Image(systemName: row.icon).font(.system(size: 14))
                                        Text(row.title).font(Theme.Typo.copy)
                                    }
                                    if let description = row.description {
                                        description
                                            .font(Theme.Typo.label)
                                            .foregroundStyle(Theme.Colors.tertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                let shortcut = Binding<KeyShortcut?>(
                                    get: { preferences.shortcuts[row.action] ?? nil },
                                    set: { preferences.shortcuts[row.action] = $0 }
                                )
                                let recorder = ShortcutRecorder(
                                    shortcut: shortcut,
                                    defaultShortcut: row.action.defaultShortcut,
                                    clearable: row.action.isGlobal,
                                    allowKeysOnly: !row.action.isGlobal
                                )
                                if row.action.isGlobal {
                                    GlobalShortcutRecorder(shortcut: shortcut.wrappedValue) { recorder }
                                } else {
                                    recorder
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Shared rows

/// "Save new projects to" style row: title, path with ~, "Change directory".
private struct FolderRow: View {
    var title: String
    var path: String
    var message: String
    var onChange: (String) -> Void

    var body: some View {
        HStack(spacing: Theme.gap(3)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typo.copy)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Colors.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RSButton(title: "Change directory", kind: .secondaryInline) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.message = message
                panel.prompt = "Select folder"
                if panel.runModal() == .OK, let url = panel.url { onChange(url.path) }
            }
        }
    }
}

/// A system-wide shortcut's chip, with "Not able to register" under it when another app
/// holds the shortcut.
private struct GlobalShortcutRecorder<Recorder: View>: View {
    var shortcut: KeyShortcut?
    @ViewBuilder var recorder: () -> Recorder
    @State private var canRegister: Bool?

    var body: some View {
        VStack(spacing: Theme.gap(0.5)) {
            recorder()
            if canRegister == false {
                Text("Not able to register")
                    .font(Theme.Typo.label)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
        .task(id: shortcut) {
            guard let shortcut else {
                canRegister = true
                return
            }
            canRegister = nil
            canRegister = GlobalHotKeys.shared.canRegister(shortcut)
        }
    }
}

/// Shortcut chip: click, press keys; Escape/mouse cancels; 5s timeout.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    var defaultShortcut: KeyShortcut
    var clearable: Bool
    var allowKeysOnly: Bool

    @State private var isRecording = false
    @State private var live = ""
    @State private var monitor: Any?
    @State private var timeout: Task<Void, Never>?
    @State private var shake = false

    var body: some View {
        HStack(spacing: Theme.gap(0)) {
            if clearable && shortcut != nil {
                RSIconButton(icon: "trash", size: .small) { shortcut = nil }
            }
            if shortcut != defaultShortcut {
                RSIconButton(icon: "arrow.counterclockwise", size: .small, tooltip: "Reset to default") { shortcut = defaultShortcut }
            }
            Button(action: startRecording) {
                Text(chipText)
                    .font(Theme.Typo.controlCopy)
                    .foregroundStyle(isRecording ? Theme.Colors.primary.opacity(0.9) : Theme.Colors.text)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 110)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
                    .offset(x: shake ? 4 : 0)
            }
            .buttonStyle(.plain)
            .tooltip("Click to change")
        }
        .onDisappear(perform: stopRecording)
    }

    private var chipText: String {
        if isRecording { return live.isEmpty ? "Press keys..." : live }
        return shortcut?.display ?? "Add shortcut"
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        live = ""
        restartTimeout()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { event in
            handle(event)
            return event.type == .keyDown ? nil : event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            stopRecording()
        case .flagsChanged:
            live = Self.modifierText(event.modifierFlags)
            restartTimeout()
        case .keyDown:
            if event.keyCode == 53 { stopRecording(); return } // Escape
            let flags = event.modifierFlags
            let candidate = KeyShortcut(
                keyCode: event.keyCode,
                key: Self.keyName(event),
                command: flags.contains(.command),
                control: flags.contains(.control),
                option: flags.contains(.option),
                shift: flags.contains(.shift)
            )
            if candidate.hasModifiers || allowKeysOnly {
                shortcut = candidate
                stopRecording()
            } else {
                withAnimation(.default.repeatCount(5, autoreverses: true).speed(6)) { shake = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { shake = false }
            }
        default:
            break
        }
    }

    private func restartTimeout() {
        timeout?.cancel()
        timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { stopRecording() }
        }
    }

    private func stopRecording() {
        isRecording = false
        live = ""
        timeout?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func modifierText(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return (event.charactersIgnoringModifiers ?? "").uppercased()
        }
    }
}
