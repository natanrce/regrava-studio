import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Global shortcuts

/// System-wide shortcuts (Carbon hot keys), re-registered when Settings change.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let handler = GlobalHotKeys.handlers[id.id]
            DispatchQueue.main.async { handler?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    func register(_ bindings: [(KeyShortcut, () -> Void)]) {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        Self.handlers.removeAll()
        for (index, binding) in bindings.enumerated() {
            let shortcut = binding.0
            var modifiers: UInt32 = 0
            if shortcut.command { modifiers |= UInt32(cmdKey) }
            if shortcut.control { modifiers |= UInt32(controlKey) }
            if shortcut.option { modifiers |= UInt32(optionKey) }
            if shortcut.shift { modifiers |= UInt32(shiftKey) }
            let id = EventHotKeyID(signature: OSType(0x5247_5354), id: UInt32(index + 1)) // "RGST"
            var reference: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr, let reference {
                references.append(reference)
                Self.handlers[id.id] = binding.1
            }
        }
    }
}

// MARK: - Menu bar status item

/// Idle: a menu of recording/project actions. While recording: no menu, a click finishes
/// the recording. The icon is an SF Symbol.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var coordinator: RecordingCoordinator?

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        refresh()
    }

    func refresh() {
        let recording = coordinator?.isRecording ?? false
        item.button?.image = NSImage(systemSymbolName: recording ? "stop.circle" : "record.circle", accessibilityDescription: "Regrava Studio")
        if recording {
            item.menu = nil
        } else {
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
        }
    }

    @objc private func clicked() {
        guard let coordinator, coordinator.isRecording else { return }
        coordinator.requestFinish()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let app = AppController.shared
        let shortcuts = Preferences.shared.shortcuts
        let builder = MenuBuilder()
        builder.item("New recording...", icon: "record.circle", shortcut: shortcuts[.recordStartStop] ?? nil) { app.recording.openPicker() }
        builder.item("Record display", icon: "dock.rectangle", shortcut: shortcuts[.recordDisplay] ?? nil) { app.recording.openPicker(preselect: .display) }
        builder.item("Record window", icon: "macwindow", shortcut: shortcuts[.recordWindow] ?? nil) { app.recording.openPicker(preselect: .window) }
        builder.item("Record area", icon: "square.dashed", shortcut: shortcuts[.recordArea] ?? nil) { app.recording.openPicker(preselect: .area) }
        builder.item("Show settings", shortcut: .make(",", keyCode: 43, "⌘")) { SettingsWindowController.shared.show() }
        builder.item("Show previous projects") { app.showPreviousProjects() }
        builder.item("Open project...", shortcut: .make("O", keyCode: 31, "⌘")) { app.openProjectPanel() }
        builder.item("Open last project", enabled: app.lastProjectURL != nil, shortcut: .make("Z", keyCode: 6, "⌥⌘")) { app.openLastProject() }
        builder.item("Show Regrava Studio in Dock", checked: !Preferences.shared.hideDockIcon, shortcut: .make("D", keyCode: 2, "⌘")) {
            Preferences.shared.hideDockIcon.toggle()
            app.applyDockIconPolicy()
        }
        builder.item("Quit app") { NSApp.terminate(nil) }
        for item in builder.menu.items {
            builder.menu.removeItem(item)
            menu.addItem(item)
        }
    }
}

// MARK: - Onboarding

/// Permissions step: Screen Recording + Accessibility, polled every 500 ms. There is no
/// terms checkbox or account step.
@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()
    private let model = OnboardingModel()

    private init() {
        let hosting = NSHostingController(rootView: OnboardingView(model: OnboardingModel.placeholder))
        // Fixed window size; don't let the SwiftUI content resize the window.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "New Recording"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 670, height: 760))
        window.minSize = NSSize(width: 670, height: 760)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.Colors.background)
        super.init(window: window)
        hosting.rootView = OnboardingView(model: model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.startPolling()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish() {
        model.stopPolling()
        close()
        AppController.shared.recording.openPicker()
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    static let placeholder = OnboardingModel()
    @Published var screenRecording = Permissions.canRecordScreen
    @Published var accessibility = Permissions.hasAccessibility
    private var timer: Timer?

    var canRecord: Bool { screenRecording && accessibility }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenRecording = Permissions.canRecordScreen
                self?.accessibility = Permissions.hasAccessibility
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.gap(4)) {
            VStack(spacing: Theme.gap(2)) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Welcome to Regrava Studio!").font(.system(size: 24, weight: .semibold))
                Text("Before you can start recording, we need to ask you for a few permissions.")
                    .font(Theme.Typo.copy.weight(.medium))
                    .opacity(Theme.secondaryOpacity)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Theme.gap(2.5)) {
                PermissionRow(
                    title: "Screen Recording Permission",
                    description: "Regrava Studio needs to capture video of your screen. You might need to restart the app after granting it.",
                    allowTitle: "Allow Screen Recording",
                    grantedTitle: "Screen Recording enabled",
                    granted: model.screenRecording,
                    action: { Permissions.requestScreenRecording() }
                )
                PermissionRow(
                    title: "Accessibility Permission",
                    description: "Regrava Studio needs to capture mouse movements and shortcut keystrokes while you are recording your screen.",
                    allowTitle: "Allow Accessibility access",
                    grantedTitle: "Accessibility access enabled",
                    granted: model.accessibility,
                    action: { Permissions.requestAccessibility() }
                )
            }
            .frame(maxWidth: 520)
            RSButton(title: "Continue", icon: "checkmark.circle.fill", kind: .primary, size: .big) {
                OnboardingWindowController.shared.finish()
            }
            .disabled(!model.canRecord)
            .opacity(model.canRecord ? 1 : 0.1)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .foregroundStyle(Theme.Colors.text)
        .scaleEffect(appeared ? 1 : 0.95)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(.easeOut(duration: 0.75)) { appeared = true } }
    }
}

private struct PermissionRow: View {
    var title: String
    var description: String
    var allowTitle: String
    var grantedTitle: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: Theme.gap(3)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typo.copy)
                Text(description).font(Theme.Typo.label).opacity(Theme.tertiaryOpacity).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                RSButton(title: grantedTitle, icon: "checkmark", kind: .success) {}
                    .allowsHitTesting(false)
            } else {
                RSButton(title: allowTitle, kind: .subtle, action: action)
            }
        }
    }
}
