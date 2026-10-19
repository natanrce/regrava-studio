import AppKit
import RegravaCore
import SwiftUI

/// An editor action listed in the command menu (names, icons and shortcuts from the
/// actions, e.g.).
struct EditorAction: Identifiable {
    var id: String { group + "/" + name }
    var name: String
    var group: String
    var icon: String
    var shortcut: String?
    var isEnabled = true
    var perform: () -> Void
}

extension EditorModel {
    /// Preview size steps of the layout controls.
    private static let previewSizes = [480, 720, 1080, 1440, 2160]

    private func stepPreviewSize(_ direction: Int) {
        let current = Preferences.shared.playbackPreviewMaxHeight
        let next = direction < 0 ? Self.previewSizes.last { $0 < current } : Self.previewSizes.first { $0 > current }
        if let next { Preferences.shared.playbackPreviewMaxHeight = next }
    }

    var commandActions: [EditorAction] {
        let finder: () -> Void = { [bundleURL] in NSWorkspace.shared.activateFileViewerSelecting([bundleURL]) }
        return [
            EditorAction(name: isPlaying ? "Pause" : "Play", group: "Playback", icon: isPlaying ? "pause.circle" : "play.circle", shortcut: "Space") { [weak self] in self?.togglePlay() },
            EditorAction(name: "Go to first frame", group: "Playback", icon: "backward.end", shortcut: "⌘ ←") { [weak self] in self?.seek(to: 0) },
            EditorAction(name: "Go to last frame", group: "Playback", icon: "forward.end", shortcut: "⌘ →") { [weak self] in self.map { $0.seek(to: $0.durationMs) } },
            EditorAction(name: "Move backwards", group: "Playback", icon: "arrow.turn.up.left", shortcut: "←") { [weak self] in self?.step(frames: -1) },
            EditorAction(name: "Move backwards fast", group: "Playback", icon: "arrow.turn.up.left", shortcut: "⇧ ←") { [weak self] in self?.step(milliseconds: -2000) },
            EditorAction(name: "Move forwards", group: "Playback", icon: "arrow.turn.up.right", shortcut: "→") { [weak self] in self?.step(frames: 1) },
            EditorAction(name: "Move forwards fast", group: "Playback", icon: "arrow.turn.up.right", shortcut: "⇧ →") { [weak self] in self?.step(milliseconds: 1000) },
            EditorAction(name: "Decrease preview size", group: "Playback", icon: "minus.magnifyingglass", isEnabled: Self.previewSizes.contains { $0 < Preferences.shared.playbackPreviewMaxHeight }) { [weak self] in self?.stepPreviewSize(-1) },
            EditorAction(name: "Increase preview size", group: "Playback", icon: "plus.magnifyingglass", isEnabled: Self.previewSizes.contains { $0 > Preferences.shared.playbackPreviewMaxHeight }) { [weak self] in self?.stepPreviewSize(1) },
            EditorAction(name: "Zoom in", group: "Playback", icon: "plus", shortcut: "⌘ =") { [weak self] in self?.zoomTimeline(in: true) },
            EditorAction(name: "Zoom out", group: "Playback", icon: "minus", shortcut: "⌘ −") { [weak self] in self?.zoomTimeline(in: false) },
            EditorAction(name: "Undo", group: "Project", icon: "arrow.uturn.backward", shortcut: "⌘ Z", isEnabled: canUndo) { [weak self] in self?.undo() },
            EditorAction(name: "Redo", group: "Project", icon: "arrow.uturn.forward", shortcut: "⌘ ⇧ Z", isEnabled: canRedo) { [weak self] in self?.redo() },
            EditorAction(name: "Show project in Finder", group: "Project", icon: "folder", shortcut: "⌘ ⇧ O", perform: finder),
            EditorAction(name: "Split at current time", group: "Slice", icon: "scissors", shortcut: "C") { [weak self] in self.map { $0.splitSlice(atPlayback: $0.currentTimeMs) } },
            EditorAction(name: "Reset trims and cuts for all slices", group: "Slice", icon: "arrowshape.turn.up.left") { [weak self] in self?.resetAllSlices() },
            EditorAction(name: "Add classic zoom", group: "Zooms", icon: "arrow.up.left.and.down.right.magnifyingglass") { [weak self] in
                self?.isAddZoomToolArmed = true
                self?.pause()
            },
            EditorAction(name: "Enable all zoom ranges", group: "Zooms", icon: "checkmark.circle") { [weak self] in self?.setAllZooms(disabled: false) },
            EditorAction(name: "Disable all zoom ranges", group: "Zooms", icon: "slash.circle") { [weak self] in self?.setAllZooms(disabled: true) },
            EditorAction(name: "Restore default zoom ranges", group: "Zooms", icon: "arrow.clockwise") { [weak self] in self?.restoreDefaultZooms() },
            EditorAction(name: "Remove all zoom ranges", group: "Zooms", icon: "trash", isEnabled: !project.zooms.isEmpty) { [weak self] in
                self.map { $0.removeZooms(Set($0.project.zooms.map(\.id))) }
            },
            // `addLayout` / `removeAllLayouts`, titled after the last layout type.
            EditorAction(name: addLayoutTitle, group: "Layouts", icon: AddToolsRail.layoutIcon(addLayoutType), shortcut: "⌃ L", isEnabled: project.recording.hasCamera) { [weak self] in
                self?.toggleAddLayoutTool()
            },
            EditorAction(name: "Remove all layouts", group: "Layouts", icon: "trash") { [weak self] in
                self.map { $0.removeLayouts(Set($0.project.cameraLayouts.map(\.id))) }
            },
            EditorAction(name: "Add sensitive data mask", group: "Masks", icon: "circle.filled.pattern.diagonalline.rectangle") { [weak self] in self?.armMaskTool(.sensitiveData) },
            EditorAction(name: "Add highlight mask", group: "Masks", icon: "circle.rectangle.filled.pattern.diagonalline") { [weak self] in self?.armMaskTool(.highlight) },
            EditorAction(name: "Disable all masks", group: "Masks", icon: "slash.circle", isEnabled: project.masks.contains { !$0.isDisabled }) { [weak self] in self?.setAllMasks(disabled: true) },
            EditorAction(name: "Remove all masks", group: "Masks", icon: "trash", isEnabled: !project.masks.isEmpty) { [weak self] in
                self.map { $0.removeMasks(Set($0.project.masks.map(\.id))) }
            },
            EditorAction(name: "Export...", group: "Export", icon: "square.and.arrow.up.fill", shortcut: "⌘ ⇧ E") { [weak self] in self?.openExportPicker() },
            EditorAction(name: "Copy current frame as image", group: "Export", icon: "document.on.document", shortcut: "⌘ C") { [weak self] in self?.copyCurrentFrame() },
            EditorAction(name: layoutType == .preview ? "Exit preview mode" : "Enter preview mode", group: "View", icon: "inset.filled.bottomhalf.rectangle", shortcut: "⌘ ⇧ ↩") { [weak self] in
                self.map { $0.layoutType = $0.layoutType == .preview ? .edit : .preview }
            },
            EditorAction(name: "General", group: "Sidebar", icon: "inset.filled.square.dashed", shortcut: "⌘ 1") { [weak self] in self?.openSidebar(.background) },
            EditorAction(name: "Cursor", group: "Sidebar", icon: "cursorarrow", shortcut: "⌘ 2") { [weak self] in self?.openSidebar(.cursor) },
            EditorAction(name: "Audio", group: "Sidebar", icon: "speaker.wave.1", shortcut: "⌘ 7") { [weak self] in self?.openSidebar(.audio) },
            EditorAction(name: "Animations", group: "Sidebar", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", shortcut: "⌘ 9") { [weak self] in self?.openSidebar(.animation) },
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

    /// Matching actions, grouped (in definition order) and sorted by name within each group.
    private var sections: [(group: String, actions: [EditorAction])] {
        let words = query.lowercased().split(separator: " ")
        // Actions that cannot apply right now are not listed.
        let matching = editor.commandActions.filter { action in
            guard action.isEnabled else { return false }
            let text = (action.name + " " + action.group).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var order: [String] = []
        for action in matching where !order.contains(action.group) { order.append(action.group) }
        return order.map { group in
            (group, matching.filter { $0.group == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    private var results: [EditorAction] { sections.flatMap(\.actions) }

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
                            VStack(alignment: .leading, spacing: 0) {
                                let sections = self.sections
                                ForEach(sections, id: \.group) { section in
                                    Text(section.group)
                                        .font(Theme.Typo.copy)
                                        .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                                        .padding(.horizontal, 20)
                                        .padding(.top, 12)
                                        .padding(.bottom, 6)
                                    ForEach(section.actions) { action in
                                        let index = results.firstIndex { $0.id == action.id } ?? 0
                                        row(action, isSelected: index == selection)
                                            .id(index)
                                            .onTapGesture {
                                                selection = index
                                                run()
                                            }
                                    }
                                }
                            }
                            .padding(.bottom, 8)
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
        HStack(spacing: 0) {
            Image(systemName: action.icon)
                .font(.system(size: 15))
                .frame(width: 22)
                .padding(.trailing, 14)
            Text(action.name).font(.system(size: 14))
            Spacer()
            if let shortcut = action.shortcut {
                ShortcutBadge(keys: shortcut)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.white.opacity(0.06) : .clear))
        .padding(.horizontal, 8)
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

/// Key badge: the shortcut's keys in a small bordered box.
struct ShortcutBadge: View {
    var keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0x2E / 255)))
    }
}
