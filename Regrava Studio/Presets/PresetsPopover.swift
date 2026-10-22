import AppKit
import RegravaCore
import SwiftUI

/// "Presets" popover.
struct PresetsPopover: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store = PresetStore.shared
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(2)) {
            if !store.hasAccess {
                HStack(alignment: .top, spacing: Theme.gap(1)) {
                    Image(systemName: "info.circle")
                    Text("There is a problem with access to presets location. Please check the troubleshooting guide.")
                }
                .font(Theme.Typo.label)
            } else if store.presets.isEmpty {
                Text("Presets will help you re-use the same project settings across projects")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.presets) { entry in
                            PresetRow(editor: editor, entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 350)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.gap(1)) {
                TextField("New preset name...", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
                RSButton(title: "Create new preset", kind: .primary, action: create)
            }
            if !store.presets.isEmpty {
                Text("Presets are not auto-updated. If you apply preset and then modify project settings - remember to update presets to reflect those changes.")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
        .frame(width: 420)
        .environment(\.colorScheme, .dark)
        .presentationBackground(Color(hex: 0x1E1E1E).opacity(0xCC / 255))
        .onAppear {
            store.reload()
            nameFocused = true
        }
        .onDisappear { editor.previewPreset(nil) }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.create(name: name, project: editor.project, bundle: editor.bundleURL)
        newName = ""
    }
}

private struct PresetRow: View {
    @ObservedObject var editor: EditorModel
    var entry: PresetStore.Entry
    @ObservedObject var store = PresetStore.shared
    @State private var hovered = false
    @State private var isRenaming = false
    @State private var draft = ""

    private var matches: Bool { entry.preset.config == editor.project.presetConfig }

    var body: some View {
        HStack(spacing: Theme.gap(1)) {
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { store.rename(entry, to: name) }
                        isRenaming = false
                    }
            } else {
                Text(entry.preset.name).font(Theme.Typo.copy).lineLimit(1)
            }
            if matches { badge("Matches project") }
            if store.isDefault(entry) { badge("Default") }
            Spacer(minLength: 0)
            Menu { menu } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tooltip("Preset options...")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.Colors.hover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            editor.previewPreset(inside ? entry : nil)
        }
        .onTapGesture { if !isRenaming { editor.applyPreset(entry) } }
        .tooltip("Click to apply")
        .contextMenu { menu }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.label)
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename...") {
            draft = entry.preset.name
            isRenaming = true
        }
        Toggle("Use as default for new projects", isOn: Binding(get: { store.isDefault(entry) }, set: { _ in store.toggleDefault(entry) }))
        if !matches {
            Button("Update to match currently edited project") {
                store.sync(entry, with: editor.project, bundle: editor.bundleURL)
                editor.toast = "Preset updated to match"
            }
        }
        Button("Show in Finder") { store.reveal(entry) }
        Divider()
        Button("Remove...", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Remove preset"
            alert.informativeText = "Are you sure you want to remove this preset?"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn { store.remove(entry) }
        }
    }
}
