import AppKit
import SwiftUI

/// Shared Start button: hero size, primary, `record.circle`, split dropdown with the
/// after-recording choice.
struct StartRecordingButton: View {
    @ObservedObject var coordinator: RecordingCoordinator
    /// What the button records; nil records the current selection.
    var target: RecordSelection?
    /// Whether the button takes Enter (a hovered display, a hovered or picked window).
    var isActive = true
    @ObservedObject var preferences = Preferences.shared
    private let anchor = AnchorHolder()

    var body: some View {
        VStack(spacing: Theme.gap(1)) {
            HStack(spacing: 0) {
                Button { press(byEnter: false) } label: {
                    HStack(spacing: Theme.gap(1)) {
                        Image(systemName: "record.circle").font(.system(size: 18))
                        Text(preferences.actionAfterRecording.startButtonTitle)
                        // While the start runs.
                        if coordinator.isStartPending { ProgressView().controlSize(.small) }
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 14)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 24)
                Button(action: showMenu) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 36, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(MenuAnchor(holder: anchor))
            }
            .font(Theme.Typo.controlCopy)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.primary))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .background(EnterShortcut(isEnabled: isActive && !pressed && !coordinator.isStartPending) { press(byEnter: true) })
    }

    /// Enter was pressed: it is not taken again by this button.
    @State private var pressed = false

    private func press(byEnter: Bool) {
        guard !coordinator.isStartPending else { return }
        if byEnter { pressed = true }
        coordinator.startPressed(target: target)
    }

    private func showMenu() {
        let menu = MenuBuilder()
        menu.header("After Recording")
        for action in [AfterRecordingAction.createProject, .exportAndCopyToClipboard, .exportAndSaveToFile] {
            menu.item(action.menuTitle, checked: preferences.actionAfterRecording == action) {
                preferences.actionAfterRecording = action
            }
        }
        menu.group("settings-zooms")
        menu.item("Automatically create zooms", checked: preferences.createAutomaticZooms) {
            preferences.createAutomaticZooms.toggle()
        }
        menu.group("settings")
        menu.item("Quick export settings...", icon: "gearshape") { SettingsWindowController.shared.show(.widget) }
        menu.popUp(below: anchor.view)
    }
}

/// Enter as a system-wide shortcut while enabled (the Start button on screen), so it works
/// from any app.
private struct EnterShortcut: View {
    var isEnabled: Bool
    var action: () -> Void
    @State private var token: UInt32?

    var body: some View {
        Color.clear
            .onAppear { update() }
            .onChange(of: isEnabled) { _, _ in update() }
            .onDisappear { unregister() }
    }

    private func update() {
        if isEnabled, token == nil {
            // 36 is Return.
            token = GlobalHotKeys.shared.register(keyCode: 36) { action() }
        } else if !isEnabled {
            unregister()
        }
    }

    private func unregister() {
        if let token { GlobalHotKeys.shared.unregister(token) }
        token = nil
    }
}
