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

    /// "Paste from clipboard" (⌘V): onto the target of the copied kind, else added at the
    /// playhead with the same duration.
    func pasteItem(_ context: ActionContext) {
        guard let clipboard = itemClipboard else { return }
        let start = currentSourceTimeMs
        switch clipboard {
        case .slice(let id, let timeScale, let volume):
            // The live clip when it still exists, onto the clip under the playhead unless
            // it is that same clip.
            guard context.single(.editor) != nil else { return }
            let live = project.slices.first { $0.id == id }
            guard let index = project.sliceIndex(atSource: start), project.slices[index].id != id else { return }
            let speed = live?.timeScale ?? timeScale, micVolume = live?.volume ?? volume
            change {
                $0.slices[index].timeScale = speed
                $0.slices[index].volume = micVolume
            }
            showToast("Slice settings pasted")
        case .zoom(let copied):
            if let target = context.singleID(.zoom) {
                updateZoom(target) {
                    $0.mode = copied.mode
                    $0.scale = copied.scale
                    $0.isDisabled = copied.isDisabled
                    $0.manualTarget = copied.manualTarget
                }
                showToast("Zoom range settings pasted")
            } else if context.single(.editor) != nil {
                let items = sortedZooms.map { (start: $0.startMs, end: $0.endMs) }
                guard let range = TimelineFreeRange.at(start, durationMs: max(copied.durationMs, ZoomRange.minimumDurationMs), items: items, minimumMs: ZoomRange.minimumDurationMs, totalMs: project.recording.durationMs) else { return }
                var zoom = copied
                zoom.id = UUID()
                zoom.startMs = range.start
                zoom.endMs = range.end
                change { $0.zooms.append(zoom) }
            }
        case .layout(let copied):
            if let target = context.singleID(.layout) {
                updateLayout(target) {
                    $0.isDisabled = copied.isDisabled
                    $0.overlayPosition01 = copied.overlayPosition01
                    $0.overlaySizeRatio01 = copied.overlaySizeRatio01
                    $0.overlayZoomedScale = copied.overlayZoomedScale
                    $0.overlayPaddingRatio01 = copied.overlayPaddingRatio01
                }
                showToast("Layout settings pasted")
            } else if context.single(.editor) != nil {
                let items = project.sortedCameraLayouts.map { (start: $0.startMs, end: $0.endMs) }
                let duration = copied.endMs - copied.startMs
                guard let range = TimelineFreeRange.at(start, durationMs: max(duration, CameraLayoutRange.minimumDurationMs), items: items, minimumMs: CameraLayoutRange.minimumDurationMs, totalMs: project.recording.durationMs) else { return }
                var layout = copied
                layout.id = UUID()
                layout.startMs = range.start
                layout.endMs = range.end
                change { $0.cameraLayouts.append(layout) }
            }
        case .mask(let copied):
            if let target = context.singleID(.mask) {
                // Everything but the id, its time range included.
                updateMask(target) { mask in
                    let id = mask.id
                    mask = copied
                    mask.id = id
                }
            } else if context.single(.editor) != nil {
                let items = project.sortedMasks.map { (start: $0.startMs, end: $0.endMs) }
                let duration = copied.endMs - copied.startMs
                guard let range = TimelineFreeRange.at(start, durationMs: max(duration, MaskRange.minimumDurationMs), items: items, minimumMs: MaskRange.minimumDurationMs, totalMs: project.recording.durationMs) else { return }
                var mask = copied
                mask.id = UUID()
                mask.startMs = range.start
                mask.endMs = range.end
                change { $0.masks.append(mask) }
            }
        }
    }
}
