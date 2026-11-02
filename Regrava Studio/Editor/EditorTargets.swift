import Foundation
import RegravaCore

/// What an action can act on: the editor and its project (always focused while the window is
/// open), the item open in the sidebar, the hovered timeline item, and the ⌘-click selection.
enum EditorTarget: Hashable {
    case editor
    case project
    case zoom(UUID)
    case slice(UUID)
    case layout(UUID)
    case mask(UUID)

    enum Kind: Hashable {
        case editor, project, zoom, slice, layout, mask

        /// The type's name, the group of its actions when there is exactly one target of it.
        var name: String? {
            switch self {
            case .editor: "Editor"
            case .project: "Project"
            case .zoom: "Zoom"
            case .slice: "Slice"
            case .layout: "Layout"
            case .mask: nil
            }
        }
    }

    var kind: Kind {
        switch self {
        case .editor: .editor
        case .project: .project
        case .zoom: .zoom
        case .slice: .slice
        case .layout: .layout
        case .mask: .mask
        }
    }

    var itemID: UUID? {
        switch self {
        case .editor, .project: nil
        case .zoom(let id), .slice(let id), .layout(let id), .mask(let id): id
        }
    }

    /// The sidebar item for a timeline item.
    init?(_ item: SidebarItem) {
        switch item {
        case .zoom(let id): self = .zoom(id)
        case .slice(let id): self = .slice(id)
        case .layout(let id): self = .layout(id)
        case .mask(let id): self = .mask(id)
        }
    }
}

/// The targets an action runs against, frozen when a shortcut is pressed or the command menu
/// opens.
struct ActionContext {
    var targets: [EditorTarget]

    static let empty = ActionContext(targets: [])

    func targets(of kind: EditorTarget.Kind) -> [EditorTarget] { targets.filter { $0.kind == kind } }
    func ids(of kind: EditorTarget.Kind) -> [UUID] { targets(of: kind).compactMap(\.itemID) }
    func has(_ kind: EditorTarget.Kind) -> Bool { targets.contains { $0.kind == kind } }

    /// The target of a kind when there is exactly one.
    func single(_ kind: EditorTarget.Kind) -> EditorTarget? {
        let matching = targets(of: kind)
        return matching.count == 1 ? matching[0] : nil
    }

    func singleID(_ kind: EditorTarget.Kind) -> UUID? { single(kind)?.itemID }
}

extension EditorModel {
    /// The current targets, leaving out items that no longer exist.
    var actionContext: ActionContext {
        ActionContext(targets: targetStack.targets { [project] target in
            switch target {
            case .editor, .project: true
            case .zoom(let id): project.zooms.contains { $0.id == id }
            case .slice(let id): project.slices.contains { $0.id == id }
            case .layout(let id): project.cameraLayouts.contains { $0.id == id }
            case .mask(let id): project.masks.contains { $0.id == id }
            }
        })
    }

    /// Pointer over a timeline item: it becomes a target until the pointer leaves.
    func focusTarget(_ target: EditorTarget) -> Int {
        targetStack.focus(target)
    }

    func unfocusTarget(_ token: Int) {
        targetStack.unfocus(token)
    }

    var hasSelection: Bool { !selectedTargets.isEmpty }

    func isSelected(_ target: EditorTarget) -> Bool { selectedTargets.contains(target) }

    /// ⌘-click on a timeline item.
    func toggleSelected(_ target: EditorTarget) {
        targetStack.toggleSelected(target)
        syncSelection()
    }

    func clearSelected() {
        targetStack.clearSelected()
        syncSelection()
    }

    func setSelected(_ targets: [EditorTarget]) {
        targetStack.setSelected(targets)
        syncSelection()
    }

    /// Drops selected items that were removed.
    func pruneSelection() {
        let project = self.project
        targetStack.removeSelected { target in
            switch target {
            case .editor, .project: false
            case .zoom(let id): !project.zooms.contains { $0.id == id }
            case .slice(let id): !project.slices.contains { $0.id == id }
            case .layout(let id): !project.cameraLayouts.contains { $0.id == id }
            case .mask(let id): !project.masks.contains { $0.id == id }
            }
        }
        syncSelection()
    }

    private func syncSelection() {
        if selectedTargets != targetStack.selected { selectedTargets = targetStack.selected }
    }

    /// The selected zooms (the zoom menu acts on them).
    var selectedZoomIDs: Set<UUID> {
        get {
            Set(selectedTargets.compactMap { target -> UUID? in
                if case .zoom(let id) = target { return id }
                return nil
            })
        }
        set { setSelected(newValue.map { EditorTarget.zoom($0) }) }
    }

    /// The highlighted outline of a timeline item: selected ones while there is a selection,
    /// otherwise the item open in the sidebar.
    func showsSelectionOutline(_ target: EditorTarget, isOpen: Bool) -> Bool {
        hasSelection ? isSelected(target) : isOpen
    }

    /// The open sidebar item is a target while the sidebar shows it.
    func refocusOpenItem() {
        if let openItemFocusToken { targetStack.unfocus(openItemFocusToken) }
        openItemFocusToken = nil
        guard layoutType.showsSidebar, let item = sidebarItem, let target = EditorTarget(item) else { return }
        openItemFocusToken = targetStack.focus(target)
    }
}
