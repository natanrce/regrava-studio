import AppKit
import Foundation
import RegravaCore

/// An action of the command menu and of the keyboard shortcuts, resolved against the targets
/// it was built for.
struct EditorAction: Identifiable {
    var id: String
    var name: String
    var group: String?
    var visibleGroup: String?
    var supplementaryLabel: String?
    var icon: String?
    /// Key names: "Meta", "Shift", "Alt", "Control", then the key ("A", "=", "ArrowLeft"…).
    var shortcut: [String]?
    /// Registered as a system-wide hotkey instead of a window shortcut.
    var isShortcutGlobal = false
    var priority = ActionPriority.normal
    /// The target type, which settles two actions sharing a shortcut.
    var targetKind: EditorTarget.Kind?
    var canApply = true
    /// Shown with a checkmark.
    var isActive = false
    var inputPlaceholder: String?
    /// Choosing the action opens these in a nested list.
    var subActions: (() -> [EditorAction])?
    var perform: (() -> Void)?

    var shortcutLabel: String? { shortcut.map(ShortcutLabel.format) }
}

enum ActionPriority {
    static let low = 0
    static let normal = 1000
    static let high = 2000
}

/// Every action, in the order the command menu lists them before a search.
@MainActor
struct ActionCatalog {
    let editor: EditorModel?
    let context: ActionContext

    private static let typeGroup = "\u{0}type"
    private var preferences: Preferences { .shared }

    var all: [EditorAction] {
        var actions: [EditorAction] = []
        actions += editorActions
        actions += projectActions
        actions += zoomActions
        actions += layoutActions
        actions += maskActions
        actions += sidebarActions
        actions += viewActions
        actions += helpActions
        actions += appActions
        actions += sliceActions
        actions += clipboardActions
        actions += recordingActions
        actions += recoveryActions
        actions += exportActions
        return actions
    }

    // MARK: Builders

    /// An action on the targets of one type: it applies only while there are such targets.
    private func target(
        _ kind: EditorTarget.Kind, _ id: String, _ name: String,
        group: String? = ActionCatalog.typeGroup, visibleGroup: String? = nil, supplementaryLabel: String? = nil, icon: String? = nil,
        shortcut: [String]? = nil, priority: Int = ActionPriority.normal, requiresSingleTarget: Bool = false,
        inputPlaceholder: String? = nil, canApply: Bool = true, isActive: Bool = false,
        subActions: (() -> [EditorAction])? = nil, perform: (() -> Void)? = nil
    ) -> EditorAction {
        let count = context.targets(of: kind).count
        let hasTargets = count > 0 && (!requiresSingleTarget || count == 1)
        return EditorAction(
            id: id, name: name,
            group: group == Self.typeGroup ? (count == 1 ? kind.name : nil) : group,
            visibleGroup: visibleGroup, supplementaryLabel: supplementaryLabel, icon: icon, shortcut: shortcut,
            priority: priority, targetKind: kind,
            canApply: hasTargets && editor != nil && canApply,
            isActive: hasTargets && isActive,
            inputPlaceholder: inputPlaceholder, subActions: subActions, perform: perform
        )
    }

    /// An action with no target type.
    private func global(
        _ id: String, _ name: String, group: String? = nil, visibleGroup: String? = nil, supplementaryLabel: String? = nil,
        icon: String? = nil, shortcut: [String]? = nil, isShortcutGlobal: Bool = false, priority: Int = ActionPriority.normal,
        canApply: Bool = true, isActive: Bool = false, subActions: (() -> [EditorAction])? = nil, perform: (() -> Void)? = nil
    ) -> EditorAction {
        EditorAction(
            id: id, name: name, group: group, visibleGroup: visibleGroup, supplementaryLabel: supplementaryLabel, icon: icon,
            shortcut: shortcut, isShortcutGlobal: isShortcutGlobal, priority: priority, canApply: canApply, isActive: isActive,
            subActions: subActions, perform: perform
        )
    }

    private var project: Project? { editor?.project }

    private func zooms(_ ids: [UUID]) -> [ZoomRange] {
        guard let project else { return [] }
        return ids.compactMap { id in project.zooms.first { $0.id == id } }
    }

    private func slices(_ ids: [UUID]) -> [Slice] {
        guard let project else { return [] }
        return ids.compactMap { id in project.slices.first { $0.id == id } }
    }

    private func layouts(_ ids: [UUID]) -> [CameraLayoutRange] {
        guard let project else { return [] }
        return ids.compactMap { id in project.cameraLayouts.first { $0.id == id } }
    }

    private func masks(_ ids: [UUID]) -> [MaskRange] {
        guard let project else { return [] }
        return ids.compactMap { id in project.masks.first { $0.id == id } }
    }

    private static func number(_ value: Double) -> String { String(format: "%g", value) }

    // MARK: Editor (playback, zoom ranges, preview)

    static let previewSizes: [(label: String, height: Int)] = [("480p", 480), ("720p", 720), ("1080p", 1080), ("1440p", 1440), ("2160p", 2160)]
    static let previewResolutions: [(label: String, value: Double)] = [("Full", 1), ("Half", 0.5), ("Quarter", 0.25)]

    /// The next preview size up or down that changes the shown preview by at least a point.
    private func nextPreviewSize(larger: Bool) -> Int? {
        let current = preferences.playbackPreviewMaxHeight
        let heights = Self.previewSizes.map(\.height)
        let candidates = larger ? heights.filter { $0 > current } : Array(heights.filter { $0 < current }.reversed())
        guard let editor, let space = editor.previewAvailableSpace else { return candidates.first }
        let canvas = editor.project.canvasSize
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        func shownHeight(_ maxHeight: Int) -> CGFloat {
            let height = min(space.height, CGFloat(maxHeight) / scale)
            guard space.width > 0, height > 0 else { return 0 }
            return canvas.height * min(space.width / canvas.width, height / canvas.height)
        }
        let shown = shownHeight(current)
        return candidates.first { abs(shownHeight($0) - shown) >= 1 }
    }

    private var editorActions: [EditorAction] {
        let e = editor
        let isPlaying = e?.isPlaying ?? false
        let zooms = project?.zooms ?? []
        return [
            target(.editor, "decreasePlaybackPreviewSize", "Decrease preview size", group: "Playback", icon: "minus.magnifyingglass", canApply: nextPreviewSize(larger: false) != nil) {
                if let size = nextPreviewSize(larger: false) { preferences.playbackPreviewMaxHeight = size }
            },
            target(.editor, "disableAllZoomRanges", "Disable all zoom ranges", group: "Zoom", icon: "slash.circle", canApply: zooms.contains { !$0.isDisabled }) {
                e?.setAllZooms(disabled: true)
            },
            target(.editor, "enableAllZoomRanges", "Enable all zoom ranges", group: "Zoom", icon: "checkmark.circle", canApply: zooms.contains { $0.isDisabled }) {
                e?.setAllZooms(disabled: false)
            },
            target(.editor, "exportCurrentFrameAsImage", "Export current frame as image...", group: "Export", icon: "square.and.arrow.up") { e?.exportCurrentFrame() },
            target(.editor, "goToFirstFrame", "Go to first frame", group: "Playback", icon: "backward.end", shortcut: ["Meta", "ArrowLeft"]) { e?.seek(to: 0) },
            target(.editor, "goToLastFrame", "Go to last frame", group: "Playback", icon: "forward.end", shortcut: ["Meta", "ArrowRight"]) { if let e { e.seek(to: e.durationMs) } },
            target(.editor, "increasePlaybackPreviewSize", "Increase preview size", group: "Playback", icon: "plus.magnifyingglass", canApply: nextPreviewSize(larger: true) != nil) {
                if let size = nextPreviewSize(larger: true) { preferences.playbackPreviewMaxHeight = size; e?.warnAboutLargerPreview() }
            },
            target(.editor, "moveBackwards", "Move backwards", group: "Playback", icon: "arrow.turn.up.left", shortcut: ["ArrowLeft"]) {
                guard let e else { return }
                e.isPlaying ? e.step(milliseconds: -1000) : e.step(frames: -1)
            },
            target(.editor, "moveBackwardsFast", "Move backwards fast", group: "Playback", icon: "arrow.turn.up.left", shortcut: ["Shift", "ArrowLeft"]) { e?.step(milliseconds: -2000) },
            target(.editor, "moveForwards", "Move forwards", group: "Playback", icon: "arrow.turn.up.right", shortcut: ["ArrowRight"]) {
                guard let e else { return }
                e.isPlaying ? e.step(milliseconds: 500) : e.step(frames: 1)
            },
            target(.editor, "moveForwardsFast", "Move forwards fast", group: "Playback", icon: "arrow.turn.up.right", shortcut: ["Shift", "ArrowRight"]) { e?.step(milliseconds: 1000) },
            target(.editor, "playBackwardOrIncreaseSpeed", "Play backward or increase speed", group: "Playback", shortcut: ["J"]) { e?.playToward(-1) },
            target(.editor, "playForwardOrIncreaseSpeed", "Play or increase speed", group: "Playback", shortcut: ["L"]) { e?.playToward(1) },
            target(.editor, "removeAllZoomRanges", "Remove all zoom ranges", group: "Zoom", icon: "trash") {
                guard let e else { return }
                if e.openZoomID != nil { e.sidebarItem = nil }
                e.removeZooms(Set(e.project.zooms.map(\.id)))
            },
            target(.editor, "restoreDefaultZoomRanges", "Restore default zoom ranges", group: "Zoom", icon: "arrow.clockwise") { e?.restoreDefaultZooms() },
            target(.editor, "setPlaybackPreviewResolution", "Preview resolution", group: "Playback", icon: "square.grid.3x3", subActions: {
                Self.previewResolutions.map { option in
                    target(.editor, "increasePlaybackPreviewResolutionTo\(Self.number(option.value))", option.label, group: "Playback resolution", visibleGroup: "resolution", isActive: preferences.playbackPreviewResolution == option.value) {
                        preferences.playbackPreviewResolution = option.value
                    }
                }
            }),
            target(.editor, "setPlaybackPreviewSize", "Preview size", group: "Playback", icon: "square.arrowtriangle.4.outward", subActions: {
                Self.previewSizes.map { option in
                    target(.editor, "setPlaybackPreviewSizeTo\(option.height)", option.label, group: "Playback", visibleGroup: "size", isActive: preferences.playbackPreviewMaxHeight == option.height) {
                        preferences.playbackPreviewMaxHeight = option.height
                    }
                }
            }),
            target(.editor, "togglePlay", isPlaying ? "Pause" : "Play", group: "Playback", icon: isPlaying ? "pause.circle" : "play.circle", shortcut: [" "]) { e?.togglePlay() },
            target(.editor, "stopAndResetSpeed", isPlaying ? "Pause" : "Play", group: "Playback", shortcut: ["K"]) { e?.togglePlay() },
            target(.editor, "toggleSplit", "Toggle split", group: "Editor", icon: "scissors") { e?.isSplitToolActive.toggle() },
            target(.editor, "zoomIn", "Zoom in", group: "Playback", icon: "plus", shortcut: ["Meta", "="]) { e?.zoomTimeline(in: true) },
            target(.editor, "zoomOut", "Zoom out", group: "Playback", icon: "minus", shortcut: ["Meta", "-"]) { e?.zoomTimeline(in: false) },
        ]
    }

    // MARK: Project

    private var projectActions: [EditorAction] {
        let e = editor
        return [
            target(.project, "copyAndZipProject", "Copy and zip project", group: "Project", icon: "square.and.arrow.down") { e?.copyAndZipProject() },
            target(.project, "deleteProject", "Remove project", group: "Project", icon: "trash") {
                guard let e, e.deleteProject() else { return }
                AppController.shared.closeEditor(for: e)
            },
            target(.project, "extractRawRecordingFiles", "Extract raw recording files...", group: "Extract", visibleGroup: "extract", icon: "square.and.arrow.down") { e?.extractRawRecordingFiles() },
            target(.editor, "openCropWindow", "Crop", group: "Editor", supplementaryLabel: "Crop recorded area", icon: "crop", canApply: project?.canChangeCrop ?? false) {
                guard let e else { return }
                e.pause()
                ScreenCropWindow.show(for: e)
            },
            global("openLastProject", "Open last project", group: "Project", visibleGroup: "open", icon: "arrow.counterclockwise", shortcut: ["Meta", "Alt", "Z"], canApply: AppController.shared.lastProjectURL != nil) {
                AppController.shared.openLastProject()
            },
            // Undo and redo keep the playhead on its recording frame.
            target(.editor, "projectRedo", "Redo", group: "Editor", icon: "arrow.uturn.forward", shortcut: ["Meta", "Shift", "Z"], canApply: e?.canRedo ?? false) {
                guard let e else { return }
                e.stickyPlayhead { e.redo() }
            },
            target(.editor, "projectUndo", "Undo", group: "Editor", icon: "arrow.uturn.backward", shortcut: ["Meta", "Z"], canApply: e?.canUndo ?? false) {
                guard let e else { return }
                e.stickyPlayhead { e.undo() }
            },
            target(.editor, "saveProject", "Save", group: "Project", icon: "square.and.arrow.down", shortcut: ["Meta", "S"]) { e?.saveFromMenu() },
            target(.project, "saveProjectAs", "Save as...", group: "Project", icon: "square.and.arrow.down", shortcut: ["Meta", "Shift", "S"]) { e?.saveAs() },
            target(.project, "showProjectInFinder", "Show project in Finder", group: "Project", icon: "folder", shortcut: ["Meta", "Shift", "O"]) {
                guard let e else { return }
                NSWorkspace.shared.activateFileViewerSelecting([e.bundleURL])
            },
        ]
    }

    // MARK: Zoom

    static let zoomLevelKeys: [(key: String, level: Double?)] = [
        ("1", 1), ("2", 1.2), ("3", 1.4), ("4", 1.6), ("5", 1.8), ("6", 2), ("7", 2.2), ("8", 2.4), ("9", 2.6), ("0", nil),
    ]
    /// The "0" level: the default zoom level when the app started.
    static let launchDefaultZoomLevel = Preferences.shared.defaultZoomLevel ?? 2

    private var changeZoomLevelActions: [EditorAction] {
        let e = editor
        let ids = context.ids(of: .zoom)
        let first = zooms(ids).first
        return Self.zoomLevelKeys.map { entry in
            let level = entry.level ?? Self.launchDefaultZoomLevel
            let label = Self.number(level)
            return target(.zoom, "changeZoomTo\(label)", "Change zoom to \(label)", visibleGroup: "Zoom level", shortcut: [entry.key], isActive: first?.scale == level) {
                guard let e else { return }
                for id in ids { e.updateZoom(id) { $0.scale = level } }
                Preferences.shared.defaultZoomLevel = level
            }
        }
    }

    private var zoomActions: [EditorAction] {
        let e = editor
        let ids = context.ids(of: .zoom)
        let targets = zooms(ids)
        let first = targets.first
        let presentationLabel: [ZoomPresentation: String] = [.screen: "Classic zoom", .loupe: "Loupe zoom"]
        let presentationIcon: [ZoomPresentation: String] = [.screen: "arrow.up.left.and.down.right.magnifyingglass", .loupe: "sparkle.magnifyingglass"]
        func changePresentation(_ presentation: ZoomPresentation, _ id: String) -> EditorAction {
            target(.zoom, id, "Change zoom to \(presentationLabel[presentation]!.lowercased())", visibleGroup: "Presentation", icon: presentationIcon[presentation], isActive: first?.presentation == presentation) {
                guard let e else { return }
                for id in ids { e.updateZoom(id) { $0.presentation = presentation } }
            }
        }
        let addPresentation = e?.addZoomPresentation ?? .screen
        return [
            target(.zoom, "applyZoomToAll", "Apply zoom level to all other zooms", visibleGroup: "Zoom level", supplementaryLabel: "Set the zoom level for all zooms to this value", icon: "plus.square", requiresSingleTarget: true) {
                guard let e, let first else { return }
                e.applyZoomLevelToAll(from: first.id)
                e.showToast("Zoom level applied to all zooms")
            },
            target(.zoom, "changeZoomLevel", "Change zoom level", visibleGroup: "Zoom level", icon: "plusminus", subActions: { changeZoomLevelActions }),
            changePresentation(.screen, "changeZoomToClassic"),
            changePresentation(.loupe, "changeZoomToLoupe"),
            target(.zoom, "decreaseZoomLevel", "Decrease zoom level", visibleGroup: "Zoom level", icon: "minus", shortcut: ["-"]) {
                guard let e, let first else { return }
                e.updateZoom(first.id) { $0.scale = clamp($0.scale - 0.2, 1, 4) }
            },
            target(.zoom, "duplicateZoom", "Duplicate zoom", visibleGroup: "General", icon: "plus", shortcut: ["Meta", "D"], requiresSingleTarget: true) {
                guard let e, let first else { return }
                e.duplicateZoom(first.id)
            },
            target(.zoom, "increaseZoomLevel", "Increase zoom level", visibleGroup: "Zoom level", icon: "plus", shortcut: ["="]) {
                guard let e, let first else { return }
                e.updateZoom(first.id) { $0.scale = (clamp($0.scale + 0.2, 1, 4) / 0.2).rounded() * 0.2 }
            },
            target(.zoom, "removeZoom", "Remove zoom", visibleGroup: "General", icon: "trash", shortcut: ["Backspace"]) {
                guard let e else { return }
                if let open = e.openZoomID, ids.contains(open) { e.sidebarItem = nil }
                e.removeZooms(Set(ids))
                e.clearSelected()
            },
            target(.zoom, "setZoomToAuto", "Set zoom type to Auto", visibleGroup: "Mode", icon: "brain", shortcut: ["A"]) {
                guard let e else { return }
                for id in ids { e.updateZoom(id) { $0.mode = .auto } }
            },
            target(.zoom, "setZoomToManual", "Set zoom type to Manual", visibleGroup: "Mode", icon: "hand.tap", shortcut: ["M"]) {
                guard let e else { return }
                for id in ids { e.updateZoom(id) { $0.mode = .manual } }
            },
            target(
                .editor, "addZoom", "Add \(presentationLabel[addPresentation]!.lowercased())", visibleGroup: "General",
                supplementaryLabel: "Click the canvas to place a zoom", icon: presentationIcon[addPresentation], isActive: e?.isAddZoomToolArmed ?? false
            ) {
                guard let e else { return }
                if e.isAddZoomToolArmed { e.isAddZoomToolArmed = false } else { e.activateAddTool(.zoom) }
            },
            target(.zoom, "toggleDisabledZoom", "Toggle zoom disabled", visibleGroup: "General", icon: "slash.circle", shortcut: ["D"], isActive: first?.isDisabled ?? false) {
                guard let e else { return }
                for id in ids { e.updateZoom(id) { $0.isDisabled.toggle() } }
            },
            target(.zoom, "toggleZoomLoupeMode", "Toggle zoom loupe mode", visibleGroup: "General", supplementaryLabel: "Toggle zoom loupe mode", icon: "plus.magnifyingglass", shortcut: ["L"], isActive: first?.presentation == .loupe) {
                guard let e, let first else { return }
                e.updateZoom(first.id) { $0.presentation = $0.presentation == .loupe ? .screen : .loupe }
            },
        ] + changeZoomLevelActions
    }

    // MARK: Camera layout

    private var layoutActions: [EditorAction] {
        let e = editor
        let ids = context.ids(of: .layout)
        let first = layouts(ids).first
        func mode(_ id: String, _ contextual: String, _ name: String, _ type: CameraLayoutType, _ icon: String, _ key: String) -> EditorAction {
            target(.layout, id, name, visibleGroup: "Layout mode", icon: icon, shortcut: [key], isActive: first?.type == type) {
                guard let e else { return }
                for id in ids { e.updateLayout(id) { $0.type = type } }
            }
        }
        let hasCamera = project?.recording.hasCamera ?? false
        let addType = e?.addLayoutType ?? .cameraOverlay
        return [
            target(.editor, "removeAllLayouts", "Remove all layouts", group: "Zoom", visibleGroup: "Layouts", icon: "trash", requiresSingleTarget: true) {
                guard let e else { return }
                e.removeLayouts(Set(e.project.cameraLayouts.map(\.id)))
            },
            target(.layout, "removeLayout", "Remove layout", icon: "trash", shortcut: ["Backspace"]) {
                guard let e else { return }
                e.removeLayouts(Set(ids))
                e.clearSelected()
            },
            mode("setLayoutModeToCameraOnly", "Fullscreen", "Set camera layout mode to fullscreen", .fullscreenCamera, "person.crop.rectangle", "2"),
            mode("setLayoutModeToCameraOverlay", "Overlay", "Set camera layout mode to camera overlay", .cameraOverlay, "square.grid.3x3", "1"),
            mode("setLayoutModeToCutoutCamera", "Cutout", "Set camera layout mode to camera cutout", .cutoutCamera, "person.and.background.dotted", "4"),
            mode("setLayoutModeToNoCamera", "Hide camera", "Set camera layout mode to hide", .screenOnly, "macwindow", "3"),
            target(
                .editor, "addLayout", e?.addLayoutTitle ?? "Add camera layout", visibleGroup: "Layouts", icon: AddToolsRail.layoutIcon(addType),
                shortcut: ["Control", "L"], requiresSingleTarget: true, canApply: hasCamera, isActive: e?.isAddLayoutToolArmed ?? false
            ) { e?.toggleAddLayoutTool() },
            target(.layout, "toggleLayoutDisabled", first.map { $0.isDisabled ? "Enable camera layout" : "Disable camera layout" } ?? "Toggle disable camera layout", visibleGroup: "Layout mode", icon: "slash.circle", shortcut: ["D"], isActive: first?.isDisabled ?? false) {
                guard let e else { return }
                for id in ids { e.updateLayout(id) { $0.isDisabled.toggle() } }
            },
        ]
    }

    // MARK: Masks

    private static let maskLabel: [MaskType: String] = [.sensitiveData: "Sensitive data mask", .highlight: "Highlight mask"]
    private static let maskIcon: [MaskType: String] = [.sensitiveData: "circle.filled.pattern.diagonalline.rectangle", .highlight: "circle.rectangle.filled.pattern.diagonalline"]

    private var maskActions: [EditorAction] {
        let e = editor
        let ids = context.ids(of: .mask)
        let first = masks(ids).first
        let allMasks = project?.masks ?? []
        let addType = e?.addMaskType ?? .sensitiveData
        func changeType(_ id: String, _ name: String, _ type: MaskType) -> EditorAction {
            target(.mask, id, name, visibleGroup: "Mask type", icon: Self.maskIcon[type], isActive: first?.type == type) {
                guard let e else { return }
                for id in ids { e.updateMask(id) { $0.type = type } }
            }
        }
        return [
            target(.editor, "addHighlightMask", "Add highlight mask", icon: Self.maskIcon[.highlight], requiresSingleTarget: true) { e?.armOrOpenMask(.highlight) },
            target(.editor, "addSensitiveDataMask", "Add sensitive data mask", icon: Self.maskIcon[.sensitiveData], requiresSingleTarget: true) { e?.armOrOpenMask(.sensitiveData) },
            target(.mask, "applyHighlightMaskOpacityToAllMasks", "Apply highlight mask opacity to all masks", requiresSingleTarget: true) {
                guard let e, let first else { return }
                e.applyHighlightOpacityToAllMasks(from: first.id)
            },
            changeType("changeMaskTypeToHighlight", "Change mask type to highlight", .highlight),
            changeType("changeMaskTypeToSensitiveData", "Change mask type to sensitive data", .sensitiveData),
            target(.editor, "disableAllMasks", "Disable all masks", visibleGroup: "Masks", icon: "slash.circle", canApply: allMasks.contains { !$0.isDisabled }) {
                e?.setAllMasks(disabled: true)
            },
            target(.mask, "finishEditingMask", "Finish editing mask", visibleGroup: "Mask", icon: "checkmark.circle", shortcut: ["Enter"], canApply: e?.openMaskID != nil) {
                e?.sidebarItem = nil
            },
            target(.editor, "removeAllMasks", "Remove all masks", visibleGroup: "Masks", icon: "trash", requiresSingleTarget: true) {
                guard let e else { return }
                e.removeMasks(Set(e.project.masks.map(\.id)))
            },
            target(.mask, "removeMask", "Remove mask", visibleGroup: "Mask", icon: "trash", shortcut: ["Backspace"]) {
                guard let e else { return }
                e.removeMasks(Set(ids))
                e.clearSelected()
            },
            target(
                .editor, "addMask", "Add \(Self.maskLabel[addType]!.lowercased())", visibleGroup: "Masks", supplementaryLabel: "Drag on the canvas to draw the mask",
                icon: Self.maskIcon[addType], requiresSingleTarget: true, isActive: e?.isAddMaskToolArmed ?? false
            ) {
                guard let e else { return }
                if e.isAddMaskToolArmed { e.isAddMaskToolArmed = false } else { e.armOrOpenMask(nil) }
            },
            target(.mask, "toggleMaskDisabled", first.map { $0.isDisabled ? "Enable mask" : "Disable mask" } ?? "Toggle disable mask", visibleGroup: "Mask", icon: "slash.circle", shortcut: ["D"], isActive: first?.isDisabled ?? false) {
                guard let e else { return }
                for id in ids { e.updateMask(id) { $0.isDisabled.toggle() } }
            },
        ]
    }

    // MARK: Sidebar

    private var sidebarActions: [EditorAction] {
        let e = editor
        func open(_ id: String, _ name: String, _ icon: String, _ key: String, _ root: SidebarRoot, canApply: Bool = true) -> EditorAction {
            let isActive = e.map { $0.sidebarItem == nil && $0.sidebarRoot == root } ?? false
            return target(.editor, id, name, group: "Sidebar", icon: icon, shortcut: ["Meta", key], canApply: canApply, isActive: isActive) { e?.openSidebar(root) }
        }
        let recording = project?.recording
        let entries = e?.railEntries ?? []
        func railEnabled(_ root: SidebarRoot) -> Bool { entries.first { $0.root == root }.map { $0.disabledTooltip == nil } ?? false }
        return [
            target(.editor, "closeCurrentSidebarPanel", "Close", group: "Sidebar", icon: "arrow.left", shortcut: ["Escape"], canApply: e.map { $0.sidebarItem != nil || $0.sidebarRoot != .background } ?? false) {
                guard let e else { return }
                if e.sidebarItem != nil { e.sidebarItem = nil } else { e.openSidebar(.background) }
            },
            open("openAnimationsSection", "Animations", "point.topleft.down.to.point.bottomright.curvepath.fill", "9", .animation),
            open("openAudioSection", "Audio", "speaker.wave.1", "7", .audio),
            open("openCameraSection", "Camera Layout", "inset.filled.rectangle.and.person.filled", "3", .cameraLayout, canApply: recording?.hasCamera ?? false),
            open("openCameraStyleSection", "Camera Style", "person.fill.viewfinder", "4", .cameraStyle, canApply: (recording?.hasCamera ?? false) && !(project?.camera.hide ?? true)),
            open("openCaptionsSection", "Captions", "captions.bubble", "5", .captions, canApply: recording?.hasMicrophone ?? false),
            open("openCursorSection", "Cursor", "cursorarrow", "2", .cursor, canApply: railEnabled(.cursor)),
            open("openDeviceFrameSection", "Device frame", "apps.iphone", "0", .deviceFrame, canApply: railEnabled(.deviceFrame)),
            open("openBackgroundSection", "General", "inset.filled.square.dashed", "1", .background),
            open("openShortcutsSection", "Keyboard Shortcuts", "command", "8", .shortcuts, canApply: !(project?.keystrokes.isEmpty ?? true)),
            open("openTranscriptSection", "Edit by transcript", "text.quote", "6", .transcript, canApply: recording?.hasMicrophone ?? false),
        ]
    }

    // MARK: View

    private var viewActions: [EditorAction] {
        let e = editor
        let layoutType = e?.layoutType ?? .edit
        return [
            global("resetWindowsPersistedBounds", "Reset windows positions", group: "Window", icon: "macwindow") { AppController.shared.resetWindowPositions() },
            global("toggleAlwaysShowTimelineScrollbar", preferences.alwaysShowTimelineScrollbar ? "Hide timeline scrollbar" : "Always show timeline scrollbar", group: "View", icon: "chevron.up.chevron.down", isActive: preferences.alwaysShowTimelineScrollbar) {
                preferences.alwaysShowTimelineScrollbar.toggle()
            },
            global("toggleAudioWaveform", "Show audio waveform", group: "View", visibleGroup: "waveform", icon: "waveform", isActive: !preferences.hideAudioWaveform) {
                preferences.hideAudioWaveform.toggle()
            },
            target(.editor, "toggleEditorPreview", "Enter preview mode", group: "View", visibleGroup: "preview", icon: "inset.filled.bottomhalf.rectangle", shortcut: ["Meta", "Shift", "Enter"], isActive: layoutType == .preview) {
                guard let e else { return }
                e.layoutType = e.layoutType == .preview ? .edit : .preview
            },
            target(.editor, "toggleEditorSidebar", "Show editor sidebar", group: "View", icon: "sidebar.squares.right", isActive: layoutType.showsSidebar) { e?.toggleSidebarShown() },
            target(.editor, "toggleEditorTimeline", "Show editor timeline", group: "View", icon: "inset.filled.bottomhalf.rectangle", isActive: layoutType.showsTimeline) { e?.toggleTimelineShown() },
            global("toggleLoopPlayback", preferences.playbackLoop ? "Disable loop playback" : "Enable loop playback", group: "Playback", icon: "repeat", isActive: preferences.playbackLoop) {
                preferences.playbackLoop.toggle()
            },
            global(
                "toggleShowSpeakerNotes", preferences.showSpeakerNotes ? "Hide speaker notes" : "Show speaker notes", group: "Recording", visibleGroup: "recording",
                icon: "text.bubble", shortcut: ["Meta", "Alt", "/"], isShortcutGlobal: true, isActive: preferences.showSpeakerNotes
            ) { preferences.showSpeakerNotes.toggle() },
            global("toggleSmoothWaveform", "Smooth waveform", group: "View", visibleGroup: "waveform", icon: "waveform", isActive: preferences.enableSmoothWaveform) {
                preferences.enableSmoothWaveform.toggle()
            },
        ]
    }

    // MARK: Help and browse

    private var helpActions: [EditorAction] {
        [
            global("openRecentClipboardExports", "Open recent Clipboard exports", group: "Browse", visibleGroup: "Clipboard", icon: "folder") { ExportController.revealClipboardExports() },
            global("showPreviousProjects", "Show previous projects", group: "Browse", visibleGroup: "Projects", icon: "folder") { AppController.shared.showPreviousProjects() },
            // No shortcuts guide window yet: the shortcut settings stand in for it.
            target(.editor, "showShortcutsGuide", "Show shortcuts guide", group: "Help", icon: "keyboard", shortcut: ["Meta", "/"]) {
                SettingsWindowController.shared.show(.shortcuts)
            },
        ]
    }

    // MARK: App

    private var appActions: [EditorAction] {
        [
            global("createProjectFromVideo", "Create project from video...", group: "File", visibleGroup: "Project", icon: "folder") { VideoImport.pickAndCreate() },
            global("importPreset", "Import preset...", group: "File", icon: "square.and.arrow.down") { PresetStore.shared.importPreset() },
            global("openProject", "Open project...", group: "File", visibleGroup: "Project", icon: "folder", shortcut: ["Meta", "O"]) { AppController.shared.openProjectPanel() },
            global("quitApp", "Quit app", group: "Dev", visibleGroup: "quit", icon: "power") { NSApp.terminate(nil) },
            global("showSettings", "Show settings", group: "Application", icon: "gear", shortcut: ["Meta", ","]) { SettingsWindowController.shared.show() },
        ]
    }

    // MARK: Slices

    private static let sliceVolumes: [Double] = [1, 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]

    private func volumeAction(
        _ id: String, _ name: String, shortcut: [String]?, canApply: Bool,
        get: @escaping (Slice) -> Double, set: @escaping (inout Slice, Double) -> Void
    ) -> EditorAction {
        let e = editor
        let ids = context.ids(of: .slice)
        let first = slices(ids).first
        return target(.slice, id, name, group: "Slice", visibleGroup: "Playback-Volume", icon: "speaker", shortcut: shortcut, canApply: canApply, subActions: {
            Self.sliceVolumes.map { volume in
                let percent = Int((volume * 100).rounded())
                return target(.slice, "\(id)\(percent)", "\(percent)%", visibleGroup: volume < 0.1 ? "muted" : volume >= 1 ? "medium" : "regular", isActive: first.map { get($0) == volume } ?? false) {
                    guard let e else { return }
                    for id in ids { e.updateSlice(id) { set(&$0, volume) } }
                }
            }
        })
    }

    private var sliceActions: [EditorAction] {
        let e = editor
        let ids = context.ids(of: .slice)
        let first = slices(ids).first
        let allSlices = project?.slices ?? []
        let firstIndex = first.flatMap { slice in allSlices.firstIndex { $0.id == slice.id } }
        let recording = project?.recording
        func hasTrim(_ index: Int) -> Bool { project.map { $0.sliceHasStartTrim(index) || $0.sliceHasEndTrim(index) } ?? false }
        let playheadIndex = e.flatMap { e in e.project.sliceIndex(atSource: e.currentSourceTimeMs) }
        return [
            target(.slice, "applySpeedToAllSlices", "Apply speed to all slices", group: "Slice", visibleGroup: "All", icon: "gauge.with.dots.needle.67percent", canApply: first.map { slice in allSlices.contains { $0.timeScale != slice.timeScale } } ?? false) {
                guard let e, let first else { return }
                e.applySpeedToAllSlices(from: first.id)
            },
            target(.slice, "mergeSliceWithNext", "Merge slice with next", group: "Slice", visibleGroup: "Trim", icon: "arrow.trianglehead.merge", canApply: firstIndex.map { $0 + 1 < allSlices.count } ?? false) {
                guard let e, let first else { return }
                e.mergeSlice(first.id, with: .next)
            },
            target(.slice, "mergeSliceWithPrevious", "Merge slice with previous", group: "Slice", visibleGroup: "Trim", icon: "arrow.trianglehead.merge", canApply: firstIndex.map { $0 > 0 } ?? false) {
                guard let e, let first else { return }
                e.mergeSlice(first.id, with: .previous)
            },
            target(.slice, "removeSlice", "Remove slice", group: "Slice", visibleGroup: "Remove", icon: "trash", shortcut: ["Backspace"], canApply: allSlices.count > 1) {
                guard let e, let first else { return }
                e.removeSlice(first.id)
            },
            target(.slice, "resetSliceTrim", "Reset slice trim", group: "Slice", visibleGroup: "Trim", icon: "arrowshape.turn.up.left", canApply: firstIndex.map(hasTrim) ?? false) {
                guard let e, let first else { return }
                e.removeSliceTrim(first.id)
            },
            target(.slice, "resetTrimsAndCutsForAllSlices", "Reset trims and cuts for all slices", group: "Slice", visibleGroup: "Reset", icon: "arrowshape.turn.up.left", canApply: allSlices.indices.contains(where: hasTrim) || allSlices.count > 1) {
                e?.resetAllSlices()
            },
            target(.editor, "rippleRemoveSlice", "Remove slice till previous cut", group: "Slice", icon: "scissors", shortcut: ["X"], canApply: (playheadIndex ?? 0) > 0) {
                _ = e?.rippleRemoveSlice()
            },
            volumeAction("setSliceExternalDeviceAudioVolume", "Set slice external device audio volume", shortcut: nil, canApply: recording?.hasExternalDeviceAudio ?? false, get: \.externalDeviceAudioVolume) { $0.externalDeviceAudioVolume = $1 },
            target(.slice, "setSliceSpeed", "Set slice speed", group: "Slice", visibleGroup: "Playback", icon: "gauge.with.dots.needle.67percent", shortcut: ["S"], subActions: {
                Slice.speedOptions.map { speed in
                    target(.slice, "setSliceSpeed\(Self.number(speed))", "\(Self.number(speed))x", visibleGroup: speed > 2 ? "fast" : speed < 1 ? "slow" : "regular", isActive: first?.timeScale == 1 / speed) {
                        guard let e else { return }
                        for id in ids { e.setSliceSpeed(id, speed) }
                    }
                }
            }),
            volumeAction("setSliceSystemAudioVolume", "Set slice system audio volume", shortcut: ["Control", "V"], canApply: recording?.hasSystemAudio ?? false, get: \.systemAudioVolume) { $0.systemAudioVolume = $1 },
            volumeAction("setSliceVolume", "Set slice volume", shortcut: ["V"], canApply: recording?.hasMicrophone ?? false, get: \.volume) { $0.volume = $1 },
            global("splitSliceAtCurrentTime", splitName, icon: "scissors", shortcut: ["C"]) { e?.splitAtPlayhead(context) },
            target(.slice, "toggleSliceDisableSmoothMouseMovement", "Disable smooth mouse movement", visibleGroup: "mouse", icon: "slash.circle", isActive: first?.disableSmoothMouseMovement ?? false) {
                guard let e else { return }
                for id in ids { e.updateSlice(id) { $0.disableSmoothMouseMovement.toggle() } }
            },
            target(.slice, "toggleSliceHideCursor", "Hide mouse cursor", visibleGroup: "mouse", icon: "eye.slash", isActive: first?.hideCursor ?? false) {
                guard let e else { return }
                for id in ids { e.updateSlice(id) { $0.hideCursor.toggle() } }
            },
        ]
    }

    private var splitName: String {
        if context.has(.slice) { return "Split at current time" }
        if context.has(.zoom) { return "Split zoom at current time" }
        if context.has(.layout) { return "Split layout at current time" }
        if context.has(.mask) { return "Split mask at current time" }
        if context.has(.editor) { return "Split slice at current time" }
        return "Split at current time"
    }

    // MARK: Clipboard

    private var clipboardActions: [EditorAction] {
        let e = editor
        let canCopy = [EditorTarget.Kind.layout, .zoom, .slice, .editor].contains { context.has($0) }
        let copyName: String =
            context.has(.slice) ? "Copy slice settings"
            : context.has(.zoom) ? "Copy zoom range"
            : context.has(.layout) ? "Copy layout"
            : context.has(.mask) ? "Copy mask"
            : context.has(.editor) ? "Copy current frame as image"
            : "Copy"
        return [
            global("copyToClipboard", copyName, group: "Clipboard", visibleGroup: "Clipboard", icon: "document.on.document", shortcut: ["Meta", "C"], canApply: canCopy && e != nil) {
                e?.copyToClipboard(context)
            },
            global("cutToClipboard", "Cut to clipboard", group: "Clipboard", visibleGroup: "Clipboard", shortcut: ["Meta", "X"], canApply: canCopy && e != nil) {
                e?.cutToClipboard(context)
            },
            global("pasteFromClipboard", "Paste from clipboard", group: "Clipboard", visibleGroup: "Clipboard", shortcut: ["Meta", "V"], canApply: e?.itemClipboard != nil) {
                e?.pasteItem(context)
            },
        ]
    }

    // MARK: Recording

    private var recordingActions: [EditorAction] {
        let recording = AppController.shared.recording
        let canCancel = recording.isRecording && !recording.isWorking
        return [
            global("addRecordingMarker", "Add recording marker", visibleGroup: "record-new", icon: "flag", shortcut: ["Meta", "Alt", "Control", "F"], isShortcutGlobal: true, canApply: recording.isRecording) {
                recording.addMarker()
            },
            global("cancelRecording", "Cancel recording", canApply: canCancel) { recording.requestCancel() },
            global("finishRecording", "Finish recording", canApply: canCancel) { recording.requestFinish() },
            global("pauseRecording", "Pause recording", shortcut: ["Meta", "Alt", "P"], isShortcutGlobal: true, canApply: recording.phase == .recording) { recording.pause() },
            global("recordArea", "Record area", visibleGroup: "record-pick", icon: "square.dashed", shortcut: ["Meta", "Alt", "5"], isShortcutGlobal: true) { recording.openPicker(preselect: .area) },
            global("recordDisplay", "Record display", visibleGroup: "record-pick", icon: "dock.rectangle", shortcut: ["Meta", "Alt", "3"], isShortcutGlobal: true) { recording.openPicker(preselect: .display) },
            global("recordStartStop", recording.isRecording ? "Stop recording" : "New recording...", visibleGroup: "record-new", icon: "record.circle", shortcut: ["Meta", "Control", "Enter"], isShortcutGlobal: true) {
                recording.isRecording ? recording.requestFinish() : recording.openPicker()
            },
            global("recordWindow", "Record window", visibleGroup: "record-pick", icon: "macwindow", shortcut: ["Meta", "Alt", "4"], isShortcutGlobal: true) { recording.openPicker(preselect: .window) },
            global("restartRecording", "Restart recording", shortcut: ["Meta", "Alt", "Backspace"], isShortcutGlobal: true, canApply: canCancel) { recording.requestRestart() },
            global("resumeRecording", "Resume recording", shortcut: ["Meta", "Alt", "P"], isShortcutGlobal: true, canApply: recording.phase == .paused) { recording.resume() },
            global("selectRecordAreaInPicker", "Record area", shortcut: ["3"], canApply: recording.isPickerOpen) { recording.openPicker(preselect: .area) },
            global("selectRecordDisplayInPicker", "Record display", shortcut: ["1"], canApply: recording.isPickerOpen) { recording.openPicker(preselect: .display) },
            global("recordWindowInPicker", "Record window", shortcut: ["2"], canApply: recording.isPickerOpen) { recording.openPicker(preselect: .window) },
            global("toggleRecordingWidget", "Show recording widget", icon: "menubar.dock.rectangle.badge.record", shortcut: ["Meta", "Alt", "'"], isShortcutGlobal: true, isActive: preferences.showRecordingWidget) {
                preferences.showRecordingWidget.toggle()
            },
            global("toggleSpeakerNotesPrompter", "Toggle speaker notes prompter", icon: SpeakerNotesStore.shared.isPlaying ? "pause" : "play", shortcut: ["Meta", "Alt", "."], isShortcutGlobal: true) {
                SpeakerNotesStore.shared.togglePlaying()
            },
        ]
    }

    private var recoveryActions: [EditorAction] {
        let recovery = RecordingRecovery.shared
        return [
            global("recoverUnfinishedRecording", recovery.actionName, visibleGroup: "unfinished-recordings", icon: "arrow.up.circle", canApply: !recovery.unfinished.isEmpty) {
                Task { await recovery.recoverAll() }
            },
            global("tryToRecoverRecordingFromRecordingFolder", "Try to recover recording from recording folder") {
                Task { await recovery.recoverFromPickedFolder() }
            },
        ]
    }

    // MARK: Export

    private var exportActions: [EditorAction] {
        let e = editor
        let canStart = !(e?.exports.isExporting ?? true)
        return [
            target(.editor, "exportToClipboardWithCurrentSettings", "Export to clipboard", group: "Export", supplementaryLabel: "with current settings", icon: "video.bubble") {
                e?.exportWithCurrentSettings(.clipboard)
            },
            target(.editor, "exportToFileWithCurrentSettings", "Export to file...", group: "Export", supplementaryLabel: "with current settings", icon: "square.and.arrow.up.fill", canApply: canStart) {
                e?.exportWithCurrentSettings(.file)
            },
            target(.editor, "openExportPicker", "Export...", group: "Export", visibleGroup: "open", icon: "square.and.arrow.up.fill", shortcut: ["Meta", "Shift", "E"], priority: ActionPriority.low, canApply: !(e.map { $0.exports.isExporting || $0.exports.isPickerOpen } ?? true)) {
                e?.openExportPicker()
            },
            target(.editor, "quickExportToClipboard", "Quick export to clipboard", group: "Export", icon: "video.bubble", shortcut: ["Meta", "Alt", "C"], canApply: canStart) { e?.quickExport(.clipboard) },
            target(.editor, "quickExportToFile", "Quick export to file...", group: "Export", icon: "square.and.arrow.up.fill", shortcut: ["Meta", "Alt", "S"], canApply: canStart) { e?.quickExport(.file) },
            target(.editor, "showPreviousClipboardExports", "Show previous clipboard exports", group: "Export", icon: "folder", priority: ActionPriority.low) {
                ExportController.revealClipboardExports()
            },
        ]
    }
}

// MARK: - Editor operations used by the actions

extension EditorModel {
    enum AddTool { case zoom, mask, layout }

    /// `activateAddTool`: pauses, closes the open item and arms the tool.
    func activateAddTool(_ tool: AddTool) {
        pause()
        sidebarItem = nil
        isAddZoomToolArmed = tool == .zoom
        isAddMaskToolArmed = tool == .mask
        isAddLayoutToolArmed = tool == .layout
    }

    /// `armAddMaskTool`: the mask under the playhead opens; otherwise the mask tool is armed
    /// (with the given type).
    func armOrOpenMask(_ type: MaskType?) {
        let time = currentSourceTimeMs
        if let mask = project.masks.first(where: { $0.startMs <= time && time <= $0.endMs }) {
            openMask(mask.id)
            return
        }
        if let type { addMaskType = type }
        activateAddTool(.mask)
    }

    /// "Split at current time" (C): a zoom, layout or mask target splits that track at the
    /// playhead, otherwise the clip under the playhead is split.
    func splitAtPlayhead(_ context: ActionContext) {
        guard context.single(.editor) != nil else { return }
        let time = currentSourceTimeMs
        let tooShort = "The part you want to cut is too short"
        if context.single(.zoom) != nil {
            guard let zoom = project.zooms.first(where: { $0.startMs <= time && time <= $0.endMs }) else { return showToast(tooShort, durationMs: 2000) }
            return splitZoom(zoom.id, at: time)
        }
        if context.single(.layout) != nil {
            guard let layout = project.cameraLayouts.first(where: { $0.startMs <= time && time <= $0.endMs }) else { return showToast(tooShort, durationMs: 2000) }
            return splitLayout(layout.id, at: time)
        }
        if context.single(.mask) != nil {
            guard let mask = project.masks.first(where: { $0.startMs <= time && time <= $0.endMs }) else { return showToast(tooShort, durationMs: 2000) }
            return splitMask(mask.id, at: time)
        }
        guard project.sliceIndex(atSource: time) != nil else { return }
        splitSlice(atPlayback: currentTimeMs)
    }

    /// The actions for the current targets.
    var actionCatalog: ActionCatalog { ActionCatalog(editor: self, context: actionContext) }

    /// A window shortcut: the matching actions that can apply; with several, the one whose
    /// target type is the first target's. False when nothing ran.
    func performShortcut(_ event: NSEvent) -> Bool {
        let context = actionContext
        let matching = ActionCatalog(editor: self, context: context).all.filter { action in
            guard !action.isShortcutGlobal, let shortcut = action.shortcut else { return false }
            return KeyChord.matches(shortcut, event)
        }
        let applicable = matching.filter(\.canApply)
        var chosen: EditorAction?
        if applicable.count == 1 {
            chosen = applicable[0]
        } else if applicable.count > 1, let first = context.targets.first {
            let sameType = applicable.filter { $0.targetKind == first.kind }
            if sameType.count == 1 { chosen = sameType[0] }
        }
        guard let chosen else { return false }
        commandMenu.execute(chosen)
        return true
    }

    var isCommandMenuOpen: Bool {
        get { commandMenu.session != nil }
        set {
            if newValue { commandMenu.open() } else { commandMenu.close() }
        }
    }
}

/// Matches a key event against an action's key names; the modifiers must match exactly.
enum KeyChord {
    private static let keyCodes: [String: Set<UInt16>] = [
        " ": [49], "Backspace": [51], "Enter": [36, 76], "Escape": [53],
        "ArrowLeft": [123], "ArrowRight": [124], "ArrowUp": [126], "ArrowDown": [125], "Tab": [48],
    ]

    static func matches(_ keys: [String], _ event: NSEvent) -> Bool {
        var required: NSEvent.ModifierFlags = []
        var key: String?
        for name in keys {
            switch name {
            case "Meta": required.insert(.command)
            case "Shift": required.insert(.shift)
            case "Alt": required.insert(.option)
            case "Control", "Ctrl": required.insert(.control)
            default: key = name
            }
        }
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == required, let key else { return false }
        if let codes = keyCodes[key] { return codes.contains(event.keyCode) }
        // Main-row characters only (the keypad has other key codes).
        guard !event.modifierFlags.contains(.numericPad) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
    }
}
