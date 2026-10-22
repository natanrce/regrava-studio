import Foundation
import RegravaCore

/// A copied timeline item: pasting it onto an item of the same kind copies its settings,
/// otherwise it is added at the playhead with the same duration.
enum ItemClipboard {
    case zoom(ZoomRange)
    case layout(CameraLayoutRange)
    case mask(MaskRange)
}

extension EditorModel {
    func copyZoom(_ id: UUID) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        itemClipboard = .zoom(zoom)
        showToast("Zoom range copied")
    }

    func copyLayout(_ id: UUID) {
        guard let layout = project.cameraLayouts.first(where: { $0.id == id }) else { return }
        itemClipboard = .layout(layout)
        showToast("Layout copied")
    }

    func copyMask(_ id: UUID) {
        guard let mask = project.masks.first(where: { $0.id == id }) else { return }
        itemClipboard = .mask(mask)
        showToast("Mask copied")
    }

    /// "Cut to clipboard": copies, then removes, with no toast.
    func cutZoom(_ id: UUID) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        itemClipboard = .zoom(zoom)
        removeZooms([id])
    }

    func cutLayout(_ id: UUID) {
        guard let layout = project.cameraLayouts.first(where: { $0.id == id }) else { return }
        itemClipboard = .layout(layout)
        removeLayouts([id])
    }

    func cutMask(_ id: UUID) {
        guard let mask = project.masks.first(where: { $0.id == id }) else { return }
        itemClipboard = .mask(mask)
        removeMasks([id])
    }

    /// ⌘V (`pasteFromClipboard`). Returns false when there is nothing to paste.
    @discardableResult
    func pasteItem() -> Bool {
        guard let clipboard = itemClipboard else { return false }
        let start = currentSourceTimeMs
        switch clipboard {
        case .zoom(let copied):
            if let target = openZoomID {
                updateZoom(target) {
                    $0.mode = copied.mode
                    $0.scale = copied.scale
                    $0.isDisabled = copied.isDisabled
                    $0.manualTarget = copied.manualTarget
                }
                showToast("Zoom range settings pasted")
            } else if let id = addZoom(startMs: start, durationMs: copied.durationMs, manualTarget: copied.mode == .manual ? copied.manualTarget : nil, presentation: copied.presentation) {
                updateZoom(id) {
                    $0.mode = copied.mode
                    $0.scale = copied.scale
                    $0.isDisabled = copied.isDisabled
                    $0.loupeOptions = copied.loupeOptions
                }
            }
        case .layout(let copied):
            if let target = openLayoutID {
                updateLayout(target) {
                    $0.isDisabled = copied.isDisabled
                    $0.overlayPosition01 = copied.overlayPosition01
                    $0.overlaySizeRatio01 = copied.overlaySizeRatio01
                    $0.overlayZoomedScale = copied.overlayZoomedScale
                    $0.overlayPaddingRatio01 = copied.overlayPaddingRatio01
                }
                showToast("Layout settings pasted")
            } else {
                guard let range = project.freeLayoutRange(startingAt: start) else {
                    toast = "Not enough space in selected timeline position to add a new layout"
                    return true
                }
                var layout = copied
                layout.id = UUID()
                layout.startMs = range.start
                layout.endMs = min(range.end, range.start + (copied.endMs - copied.startMs))
                change { $0.cameraLayouts.append(layout) }
                openLayout(layout.id)
            }
        case .mask(let copied):
            if let target = openMaskID {
                updateMask(target) {
                    $0.isDisabled = copied.isDisabled
                    $0.type = copied.type
                    $0.bounds = copied.bounds
                    $0.blur = copied.blur
                    $0.highlightMaskOpacity = copied.highlightMaskOpacity
                }
            } else {
                guard let free = freeMaskRange(around: start) else { return true }
                let end = min(free.end, start + (copied.endMs - copied.startMs))
                guard end - start >= MaskRange.minimumDurationMs else {
                    toast = "Not enough space in selected timeline position to add a new mask"
                    return true
                }
                var mask = copied
                mask.id = UUID()
                mask.startMs = start
                mask.endMs = end
                change { $0.masks.append(mask) }
                openMask(mask.id)
            }
        }
        return true
    }
}
