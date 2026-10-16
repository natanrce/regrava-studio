import RegravaCore
import SwiftUI

extension EditorModel {
    /// Binding into the project; edits through the same key coalesce into one undo step.
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<Project, T>, coalesce: String? = nil) -> Binding<T> {
        Binding(
            get: { self.project[keyPath: keyPath] },
            set: { value in self.change(coalesce: coalesce ?? String(describing: keyPath)) { $0[keyPath: keyPath] = value } }
        )
    }

    func zoomBinding<T: Equatable>(_ id: UUID, _ keyPath: WritableKeyPath<ZoomRange, T>) -> Binding<T> {
        Binding(
            get: { self.project.zooms.first { $0.id == id }?[keyPath: keyPath] ?? ZoomRange(startMs: 0, endMs: 1)[keyPath: keyPath] },
            set: { value in self.updateZoom(id, coalesce: "zoom-\(id)-\(keyPath)") { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Section rail

struct SidebarRailEntry {
    var root: SidebarRoot
    var name: String
    var icon: String
    var key: KeyEquivalent
    var disabledTooltip: String?
}

extension EditorModel {
    /// Rail entries with the enable conditions; features this app does not implement
    /// yet are disabled with an explanation.
    var railEntries: [SidebarRailEntry] {
        let notYet = "Not available in this version of Regrava Studio yet"
        return [
            SidebarRailEntry(root: .background, name: "General", icon: "inset.filled.square.dashed", key: "1"),
            SidebarRailEntry(root: .cursor, name: "Cursor", icon: "cursorarrow", key: "2", disabledTooltip: project.mouseEvents.isEmpty ? "There is no mouse cursor recorded" : nil),
            SidebarRailEntry(root: .cameraLayout, name: "Camera Layout", icon: "inset.filled.rectangle.and.person.filled", key: "3", disabledTooltip: "No camera recorded"),
            SidebarRailEntry(root: .cameraStyle, name: "Camera Style", icon: "person.fill.viewfinder", key: "4", disabledTooltip: "No camera recorded"),
            SidebarRailEntry(root: .captions, name: "Captions", icon: "captions.bubble", key: "5", disabledTooltip: notYet),
            SidebarRailEntry(root: .transcript, name: "Edit by transcript", icon: "text.quote", key: "6", disabledTooltip: notYet),
            SidebarRailEntry(root: .audio, name: "Audio", icon: "speaker.wave.1", key: "7", disabledTooltip: notYet),
            SidebarRailEntry(root: .shortcuts, name: "Keyboard Shortcuts", icon: "command", key: "8", disabledTooltip: "No keyboard shortcuts during recording"),
            SidebarRailEntry(root: .animation, name: "Animations", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", key: "9"),
        ]
    }
}

/// Vertical icon buttons (padding 12, radius 6), tooltip on the left, disabled at 0.3,
/// active in the primary colour with a 4×4 dot.
struct SidebarRail: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.gap(1)) {
            ForEach(editor.railEntries, id: \.root) { entry in
                RailButton(entry: entry, isActive: editor.sidebarItem == nil && editor.sidebarRoot == entry.root && editor.layoutType.showsSidebar) {
                    editor.openSidebar(entry.root)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 40)
    }
}

private struct RailButton: View {
    var entry: SidebarRailEntry
    var isActive: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: entry.icon)
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                .padding(12)
                .foregroundStyle(isActive ? Theme.Colors.primary.opacity(0.95) : Theme.Colors.text)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered && entry.disabledTooltip == nil ? Theme.Colors.hover : .clear))
                .overlay(alignment: .trailing) {
                    if isActive {
                        Circle().fill(Theme.Colors.primary).frame(width: 4, height: 4).padding(.trailing, 5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(entry.key, modifiers: .command)
        .disabled(entry.disabledTooltip != nil)
        .opacity(entry.disabledTooltip != nil ? 0.3 : 1)
        .onHover { hovered = $0 }
        .help(entry.disabledTooltip ?? entry.name)
    }
}

// MARK: - Panel

/// 360 px panel, backgroundAccent, radius 20/8/8/20, scroll padding 32×24.
struct SidebarPanel: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let id = editor.openZoomID {
                    RSButton(title: "Close Zoom editor", icon: "arrow.left", kind: .secondary) { editor.sidebarItem = nil }
                        .padding(.bottom, Theme.gap(3))
                    ZoomInspector(editor: editor, zoomID: id)
                } else if let id = editor.openSliceID {
                    RSButton(title: "Close Slice editor", icon: "arrow.left", kind: .secondary) { editor.sidebarItem = nil }
                        .padding(.bottom, Theme.gap(3))
                    SliceInspector(editor: editor, sliceID: id)
                } else {
                    switch editor.sidebarRoot {
                    case .cursor: CursorPanel(editor: editor)
                    case .animation: AnimationsPanel(editor: editor)
                    default: GeneralPanel(editor: editor)
                    }
                }
            }
            .padding(.vertical, 32)
            .padding(.leading, 24)
            .padding(.trailing, 8)
        }
        .scrollIndicators(.automatic)
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 8, topTrailingRadius: 8)
                .fill(Theme.Colors.backgroundAccent)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 8, topTrailingRadius: 8))
    }
}
