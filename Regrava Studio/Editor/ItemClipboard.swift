import Foundation
import RegravaCore

/// A copied timeline item: pasting it onto an item of the same kind copies its settings,
/// otherwise it is added at the playhead with the same duration.
enum ItemClipboard {
    case zoom(ZoomRange)
    case layout(CameraLayoutRange)
    case mask(MaskRange)
    /// A clip's speed and microphone volume (pasted onto the clip under the playhead).
    case slice(id: UUID, timeScale: Double, volume: Double)
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

    func copySlice(_ id: UUID) {
        guard let slice = project.slices.first(where: { $0.id == id }) else { return }
        itemClipboard = .slice(id: id, timeScale: slice.timeScale, volume: slice.volume)
        showToast("Slice settings copied")
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

    /// "Copy…" (⌘C) on the targets: a single zoom, layout or mask, else a clip's settings, else
    /// the current frame.
    func copyToClipboard(_ context: ActionContext) {
        if let zoom = context.singleID(.zoom) { copyZoom(zoom) }
        else if let layout = context.singleID(.layout) { copyLayout(layout) }
        else if let mask = context.singleID(.mask) { copyMask(mask) }
        else if let slice = context.singleID(.slice) { copySlice(slice) }
        else if context.single(.editor) != nil { copyCurrentFrame() }
    }

    /// "Cut to clipboard" (⌘X): a clip cannot be cut.
    func cutToClipboard(_ context: ActionContext) {
        if context.has(.slice) {
            showToast("Slice cannot be cut")
            return
        }
        if let zoom = context.singleID(.zoom) { cutZoom(zoom) }
        else if let layout = context.singleID(.layout) { cutLayout(layout) }
        else if let mask = context.singleID(.mask) { cutMask(mask) }
    }

    /// ⌘V (`pasteFromClipboard`). Returns false when there is nothing to paste.
    @discardableResult
    func pasteItem() -> Bool {
        guard let clipboard = itemClipboard else { return false }
        let start = currentSourceTimeMs
        switch clipboard {
        case .slice(let id, let timeScale, let volume):
            // The live clip when it still exists, onto the clip under the playhead unless
            // it is that same clip.
            let live = project.slices.first { $0.id == id }
            guard let index = project.sliceIndex(atSource: start), project.slices[index].id != id else { return true }
            let speed = live?.timeScale ?? timeScale, micVolume = live?.volume ?? volume
            change {
                $0.slices[index].timeScale = speed
                $0.slices[index].volume = micVolume
            }
            showToast("Slice settings pasted")
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
