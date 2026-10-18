import AppKit
import RegravaCore
import SwiftUI

/// An editor action listed in the command menu (names and shortcuts from the actions).
struct EditorAction: Identifiable {
    var id: String { group + "/" + name }
    var name: String
    var group: String
    var shortcut: String?
    var isEnabled = true
    var perform: () -> Void
}

extension EditorModel {
    var commandActions: [EditorAction] {
        let finder: () -> Void = { [bundleURL] in NSWorkspace.shared.activateFileViewerSelecting([bundleURL]) }
        return [
            EditorAction(name: isPlaying ? "Pause" : "Play", group: "Playback", shortcut: "Space") { [weak self] in self?.togglePlay() },
            EditorAction(name: "Go to first frame", group: "Playback", shortcut: "⌘←") { [weak self] in self?.seek(to: 0) },
            EditorAction(name: "Go to last frame", group: "Playback", shortcut: "⌘→") { [weak self] in self.map { $0.seek(to: $0.durationMs) } },
            EditorAction(name: "Move backwards", group: "Playback", shortcut: "←") { [weak self] in self?.step(frames: -1) },
            EditorAction(name: "Move forwards", group: "Playback", shortcut: "→") { [weak self] in self?.step(frames: 1) },
            EditorAction(name: "Zoom in", group: "Playback", shortcut: "⌘=") { [weak self] in self?.zoomTimeline(in: true) },
            EditorAction(name: "Zoom out", group: "Playback", shortcut: "⌘−") { [weak self] in self?.zoomTimeline(in: false) },
            EditorAction(name: "Undo", group: "Editor", shortcut: "⌘Z", isEnabled: canUndo) { [weak self] in self?.undo() },
            EditorAction(name: "Redo", group: "Editor", shortcut: "⌘⇧Z", isEnabled: canRedo) { [weak self] in self?.redo() },
            EditorAction(name: "Split clip", group: "Editor", shortcut: "⌥") { [weak self] in self?.isSplitToolActive.toggle() },
            EditorAction(name: "Split at current time", group: "Slice", shortcut: "C") { [weak self] in self.map { $0.splitSlice(atPlayback: $0.currentTimeMs) } },
            EditorAction(name: "Reset trims and cuts for all slices", group: "Slice") { [weak self] in self?.resetAllSlices() },
            EditorAction(name: "Add zoom", group: "Zooms") { [weak self] in
                self?.isAddZoomToolArmed = true
                self?.pause()
            },
            EditorAction(name: "Enable all zoom ranges", group: "Zooms") { [weak self] in self?.setAllZooms(disabled: false) },
            EditorAction(name: "Disable all zoom ranges", group: "Zooms") { [weak self] in self?.setAllZooms(disabled: true) },
            EditorAction(name: "Restore default zoom ranges", group: "Zooms") { [weak self] in self?.restoreDefaultZooms() },
            EditorAction(name: "Remove all zoom ranges", group: "Zooms", isEnabled: !project.zooms.isEmpty) { [weak self] in
                self.map { $0.removeZooms(Set($0.project.zooms.map(\.id))) }
            },
            EditorAction(name: "Add sensitive data mask", group: "Masks") { [weak self] in self?.armMaskTool(.sensitiveData) },
            EditorAction(name: "Add highlight mask", group: "Masks") { [weak self] in self?.armMaskTool(.highlight) },
            EditorAction(name: "Disable all masks", group: "Masks", isEnabled: project.masks.contains { !$0.isDisabled }) { [weak self] in self?.setAllMasks(disabled: true) },
            EditorAction(name: "Remove all masks", group: "Masks", isEnabled: !project.masks.isEmpty) { [weak self] in
                self.map { $0.removeMasks(Set($0.project.masks.map(\.id))) }
            },
            EditorAction(name: "Export...", group: "Export", shortcut: "⌘⇧E") { [weak self] in self?.openExportPicker() },
            EditorAction(name: "Copy current frame as image", group: "Export", shortcut: "⌘C") { [weak self] in self?.copyCurrentFrame() },
            EditorAction(name: "Show project in Finder", group: "Project", shortcut: "⌘⇧O", perform: finder),
            EditorAction(name: layoutType == .preview ? "Exit preview mode" : "Enter preview mode", group: "View", shortcut: "⌘⇧↩") { [weak self] in
                self.map { $0.layoutType = $0.layoutType == .preview ? .edit : .preview }
            },
            EditorAction(name: "General", group: "Sidebar", shortcut: "⌘1") { [weak self] in self?.openSidebar(.background) },
            EditorAction(name: "Cursor", group: "Sidebar", shortcut: "⌘2") { [weak self] in self?.openSidebar(.cursor) },
            EditorAction(name: "Audio", group: "Sidebar", shortcut: "⌘7") { [weak self] in self?.openSidebar(.audio) },
            EditorAction(name: "Animations", group: "Sidebar", shortcut: "⌘9") { [weak self] in self?.openSidebar(.animation) },
        ]
    }
}

/// Command menu: full-window overlay at 0.9, a 640 px card (#1e1e1eee, 1 px
/// #ffffff2e, radius 16), 64 px input "Type to find a command".
struct CommandMenuOverlay: View {
    @ObservedObject var editor: EditorModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [EditorAction] {
        let words = query.lowercased().split(separator: " ")
        return editor.commandActions.filter { action in
            let text = (action.name + " " + action.group).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Theme.Colors.background.opacity(0.9)
                    .onTapGesture { close() }
                VStack(spacing: 0) {
                    TextField("Type to find a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .foregroundStyle(Color(red: 228 / 255, green: 229 / 255, blue: 233 / 255))
                        .tint(Theme.Colors.primary)
                        .padding(20)
                        .frame(height: 64)
                        .focused($focused)
                        .onSubmit(run)
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { selection = 0 }
                    Rectangle().fill(Color.white.opacity(0x2E / 255)).frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, action in
                                    row(action, isSelected: index == selection)
                                        .id(index)
                                        .onTapGesture {
                                            selection = index
                                            run()
                                        }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selection) { proxy.scrollTo(selection) }
                    }
                }
                .frame(maxWidth: 640)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(hex: 0x1E1E1E).opacity(0xEE / 255))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                )
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0x2E / 255)))
                .padding(.horizontal, 80)
                .padding(.top, max(geometry.size.height / 2 - 210, 80))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { focused = true }
    }

    private func row(_ action: EditorAction, isSelected: Bool) -> some View {
        HStack(spacing: Theme.gap(2)) {
            Text(action.name).font(Theme.Typo.copy)
            Spacer()
            Text(action.group).font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary)
            if let shortcut = action.shortcut {
                Text(shortcut).font(Theme.Typo.label).foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(isSelected ? Theme.Colors.hover : .clear)
        .opacity(action.isEnabled ? 1 : Theme.disabledOpacity)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func run() {
        guard results.indices.contains(selection) else { return }
        let action = results[selection]
        guard action.isEnabled else { return }
        close()
        action.perform()
    }

    private func close() {
        editor.isCommandMenuOpen = false
    }
}
