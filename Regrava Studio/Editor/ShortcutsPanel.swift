import AppKit
import RegravaCore
import SwiftUI

// "Keyboard Shortcuts" sidebar panel and the timeline's Shortcuts track.

/// `ShortcutsSettings`.
struct ShortcutsPanel: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        SidebarSection(title: "Shortcuts", showsDivider: false) {
            ToggleRow(title: "Show shortcuts", description: "Show pressed shortcut labels in the video.", isOn: editor.binding(\.captions.enableShortcuts))
            if editor.project.captions.enableShortcuts {
                SliderField(
                    name: "Shortcut labels size",
                    value: editor.binding(\.captions.shortcutsSizeRatio, coalesce: "shortcuts-size"),
                    range: 0.075...0.25,
                    preview: { "\(Int(($0 * 100).rounded()))%" },
                    resetValue: 0.1
                )
                ToggleRow(
                    title: "Show single key shortcuts",
                    description: "By default, only 2+ keys shortcuts are shown. Enable this option to show single letter shortcuts as well.",
                    isOn: editor.binding(\.captions.showShortcutsWithSingleLetters)
                )
            }
        }
    }
}

extension EditorModel {
    /// The Shortcuts track is shown only while its panel is open.
    var showsShortcutsTrack: Bool {
        sidebarItem == nil && sidebarRoot == .shortcuts && !project.keystrokes.isEmpty
    }

    /// Click on a chip. With shortcuts off, enabling from a chip shows only that shortcut.
    func toggleShortcut(_ item: ShortcutTrackItem, among items: [ShortcutTrackItem]) {
        change { project in
            var hidden = project.captions.hiddenShortcuts
            if project.captions.enableShortcuts {
                if hidden[item.id] == true { hidden[item.id] = nil } else { hidden[item.id] = true }
            } else {
                if hidden.isEmpty { for other in items { hidden[other.id] = true } }
                hidden[item.id] = nil
                project.captions.enableShortcuts = true
            }
            project.captions.hiddenShortcuts = hidden
        }
    }

    func setShortcuts(_ ids: [String], visible: Bool) {
        change { project in
            for id in ids { project.captions.hiddenShortcuts[id] = visible ? nil : true }
        }
    }

    /// "Show all shortcuts" writes `{}`; "Hide all shortcuts" hides every item.
    func setAllShortcuts(visible: Bool, items: [ShortcutTrackItem]) {
        change { project in
            project.captions.hiddenShortcuts = visible ? [:] : Dictionary(uniqueKeysWithValues: items.map { ($0.id, true) })
        }
    }
}

/// The Shortcuts track: chips for every press; clicking one hides or shows it.
struct ShortcutsTrack: View {
    @ObservedObject var editor: EditorModel
    var geometry: TimelineGeometry
    @State private var hoveringTrack = false
    @State private var focusTask: Task<Void, Never>?

    private var isFocused: Bool { editor.focusedTrack == "shortcuts" }

    var body: some View {
        let height: CGFloat = isFocused ? 48 : 16
        let items = KeyboardShortcuts.trackItems(project: editor.project)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(height: height)
                .nativeContextMenu { [editor] in [[ShortcutChip.allRow(editor, items)]] }
            ForEach(items) { item in
                ShortcutChip(editor: editor, item: item, items: items, geometry: geometry, height: height, isFocused: isFocused)
            }
            if !isFocused {
                Text("Shortcuts")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                    .padding(.leading, 20)
                    .padding(.trailing, 120)
                    .frame(height: 16)
                    .background(LinearGradient(colors: [Theme.Colors.background, Theme.Colors.background.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .tooltip(isFocused ? "" : "Shortcuts track")
        .onHover { inside in
            hoveringTrack = inside
            focusTask?.cancel()
            if inside && !isFocused {
                focusTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if !Task.isCancelled && hoveringTrack { editor.focusedTrack = "shortcuts" }
                }
            }
        }
    }
}

/// A chip.
private struct ShortcutChip: View {
    @ObservedObject var editor: EditorModel
    var item: ShortcutTrackItem
    var items: [ShortcutTrackItem]
    var geometry: TimelineGeometry
    var height: CGFloat
    var isFocused: Bool
    @State private var hovered = false

    private var isHidden: Bool { editor.project.captions.hiddenShortcuts[item.id] == true }
    private var isDisabled: Bool { isHidden || !editor.project.captions.enableShortcuts }

    private var labelWidth: CGFloat {
        (item.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
    }

    private var tooltip: String {
        if !editor.project.captions.enableShortcuts { return "Enable shortcuts" }
        return isHidden ? "Show shortcut" : "Hide shortcut"
    }

    var body: some View {
        let width = max(geometry.sx(item.endMs) - geometry.sx(item.startMs), 1)
        let primary = Theme.Colors.primary
        let shape = RoundedRectangle(cornerRadius: 6)
        let outline = isDisabled ? (hovered ? primary.opacity(Theme.tertiaryOpacity) : primary.opacity(0.1)) : (hovered ? primary.opacity(0.7) : primary)
        Button { editor.toggleShortcut(item, among: items) } label: {
            shape
                .fill(LinearGradient(colors: [primary.opacity(0.4), primary.opacity(0)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [primary.opacity(0.4), primary.opacity(0)], startPoint: .bottom, endPoint: .top))
                        .opacity(0.3)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                }
                .overlay {
                    if isFocused {
                        Text(item.label)
                            .font(Theme.Typo.copy.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 4)
                            .offset(y: -2)
                    }
                }
                .overlay { shape.strokeBorder(outline, lineWidth: 1) }
                .shadow(color: isDisabled ? .clear : primary.opacity(0.2), radius: 5)
                .contentShape(shape)
        }
        .buttonStyle(ChipPressStyle())
        .frame(width: width, height: height)
        .onHover { hovered = $0 }
        // The label is appended when it doesn't fit the chip.
        .tooltip(tooltip + (labelWidth + 8 > width ? " " + item.label : ""))
        .nativeContextMenu { menu }
        .offset(x: geometry.sx(item.startMs))
    }

    /// Switches for this shortcut and every one like it, then show/hide all.
    private var menu: [[MenuRow]] {
        var single: [MenuRow] = [
            .toggle(title: "Show this shortcut", isOn: !isHidden) { [editor, item] on in editor.setShortcuts([item.id], visible: on) },
        ]
        let same = items.filter { $0.press.shortcut == item.press.shortcut }
        if same.count >= 2 {
            let allVisible = same.allSatisfy { editor.project.captions.hiddenShortcuts[$0.id] != true }
            single.append(.toggle(title: "Show every \(item.label)", isOn: allVisible) { [editor] on in editor.setShortcuts(same.map(\.id), visible: on) })
        }
        return [single, [Self.allRow(editor, items)]]
    }

    /// "Hide all shortcuts" / "Show all shortcuts" (also the track's own menu).
    static func allRow(_ editor: EditorModel, _ items: [ShortcutTrackItem]) -> MenuRow {
        let allHidden = editor.project.captions.hiddenShortcuts.count == items.count
        return .command(.init(title: allHidden ? "Show all shortcuts" : "Hide all shortcuts") { editor.setAllShortcuts(visible: allHidden, items: items) })
    }
}

/// `:active` moves the chip 1 px down.
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? 1 : 0)
    }
}
