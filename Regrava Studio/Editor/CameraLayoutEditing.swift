import AppKit
import RegravaCore

// Camera layout ranges on the timeline: (actions), (track), (collection).

extension EditorModel {
    var openLayoutID: UUID? {
        if case .layout(let id) = sidebarItem { return id }
        return nil
    }

    /// Opening a layout focuses the "camera-mode" track.
    func openLayout(_ id: UUID) {
        sidebarItem = .layout(id)
        selectedZoomIDs = []
        focusedTrack = "camera-mode"
    }

    /// `armOrAddLayoutOfType`: after making sure the webcam is shown, camera overlay arms the
    /// add tool; the other types are added at the playhead straight away.
    func armOrAddLayout(_ type: CameraLayoutType) {
        if type != .screenOnly && !ensureProjectWebcamShown() { return }
        addLayoutType = type
        if type == .cameraOverlay {
            if isAddLayoutToolArmed {
                isAddLayoutToolArmed = false
                return
            }
            isAddLayoutToolArmed = true
            isAddZoomToolArmed = false
            isAddMaskToolArmed = false
            pause()
            sidebarItem = nil
            return
        }
        addLayoutAtPlayhead(type)
    }

    /// `addLayout` (⌃L): disarms the armed tool, otherwise repeats the last chosen type.
    func toggleAddLayoutTool() {
        guard project.recording.hasCamera else { return }
        if isAddLayoutToolArmed {
            isAddLayoutToolArmed = false
            return
        }
        armOrAddLayout(addLayoutType)
    }

    /// "Add camera overlay layout", "Add split screen layout"…
    var addLayoutTitle: String {
        switch addLayoutType {
        case .cameraOverlay: "Add camera overlay layout"
        case .splitScreen: "Add split screen layout"
        case .cutoutCamera: "Add camera cutout layout"
        case .fullscreenCamera: "Add fullscreen camera layout"
        case .screenOnly: "Add hide-camera layout"
        }
    }

    /// `ensureProjectWebcamShown`: asks to turn "Hide camera" off.
    private func ensureProjectWebcamShown() -> Bool {
        guard project.camera.hide else { return true }
        let alert = NSAlert()
        alert.messageText = "Enable webcam"
        alert.informativeText = "Webcam is disabled in your project, do you want to enable it?"
        alert.addButton(withTitle: "Enable webcam")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        change { $0.camera.hide = false }
        return true
    }

    /// `addLayoutAtPlayhead`: 3 s from the playhead within the free space, opened, and the
    /// playhead moved to its middle.
    func addLayoutAtPlayhead(_ type: CameraLayoutType, overlayPosition01: Vec2? = nil) {
        isAddLayoutToolArmed = false
        guard let range = project.freeLayoutRange(startingAt: currentSourceTimeMs) else {
            toast = "Not enough space in selected timeline position to add a new layout"
            return
        }
        insertLayout(CameraLayoutRange(startMs: range.start, endMs: range.end, type: type, overlayPosition01: overlayPosition01 ?? Vec2(1, 1)))
    }

    /// Layout created from the track (click or drag on the empty area): always camera overlay.
    func addLayout(startMs: Double, endMs: Double) {
        insertLayout(CameraLayoutRange(startMs: startMs, endMs: endMs))
    }

    private func insertLayout(_ layout: CameraLayoutRange) {
        change { $0.cameraLayouts.append(layout) }
        openLayout(layout.id)
        if !isPlaying { seek(to: project.resolver.sourceToPlayback(layout.midMs)) }
    }

    func updateLayout(_ id: UUID, coalesce: String? = nil, _ body: (inout CameraLayoutRange) -> Void) {
        change(coalesce: coalesce) { project in
            guard let index = project.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
            body(&project.cameraLayouts[index])
        }
    }

    func freeLayoutRange(around timeMs: Double) -> (start: Double, end: Double)? {
        let sorted = project.sortedCameraLayouts
        if sorted.contains(where: { $0.contains(timeMs) && $0.endMs > timeMs }) { return nil }
        let start = sorted.last(where: { $0.endMs <= timeMs })?.endMs ?? 0
        let end = sorted.first(where: { $0.startMs >= timeMs })?.startMs ?? project.recording.durationMs
        return (start, end)
    }

    func moveLayout(_ id: UUID, toStart start: Double) {
        guard let layout = project.cameraLayouts.first(where: { $0.id == id }) else { return }
        let others = project.sortedCameraLayouts.filter { $0.id != id }
        let lower = others.last(where: { $0.endMs <= layout.startMs + 0.5 })?.endMs ?? 0
        let upper = others.first(where: { $0.startMs >= layout.endMs - 0.5 })?.startMs ?? project.recording.durationMs
        let newStart = clamp(start, lower, upper - layout.durationMs)
        updateLayout(id, coalesce: "drag-\(id)") {
            $0.startMs = newStart
            $0.endMs = newStart + layout.durationMs
        }
    }

    func resizeLayout(_ id: UUID, leading: Bool, to time: Double) {
        guard let layout = project.cameraLayouts.first(where: { $0.id == id }) else { return }
        let others = project.sortedCameraLayouts.filter { $0.id != id }
        let minimum = CameraLayoutRange.minimumDurationMs
        updateLayout(id, coalesce: "resize-\(id)") {
            if leading {
                let lower = others.last(where: { $0.endMs <= layout.startMs + 0.5 })?.endMs ?? 0
                $0.startMs = clamp(time, lower, layout.endMs - minimum)
            } else {
                let upper = others.first(where: { $0.startMs >= layout.endMs - 0.5 })?.startMs ?? project.recording.durationMs
                $0.endMs = clamp(time, layout.startMs + minimum, upper)
            }
        }
    }

    /// `splitAt`: both parts must keep the 500 ms minimum.
    func splitLayout(_ id: UUID, at timeMs: Double) {
        guard let layout = project.cameraLayouts.first(where: { $0.id == id }) else { return }
        let minimum = CameraLayoutRange.minimumDurationMs
        guard timeMs - layout.startMs >= minimum, layout.endMs - timeMs >= minimum else {
            NSSound.beep()
            return
        }
        var second = layout
        second.id = UUID()
        second.startMs = timeMs
        change { project in
            guard let index = project.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
            project.cameraLayouts[index].endMs = timeMs
            project.cameraLayouts.append(second)
        }
    }

    func removeLayouts(_ ids: Set<UUID>) {
        change { $0.cameraLayouts.removeAll { ids.contains($0.id) } }
    }

    /// Where the camera would sit for each overlay position, in fractions of the stage, with
    /// the corner radius in fractions of the stage width.
    var overlayPlacementCandidates: [(position01: Vec2, rect01: Rect2, borderRadius01: Double)] {
        OptionDotPicker.eightPositions.compactMap { position in
            let resolver = project.resolver(for: CameraLayoutRange(startMs: 0, endMs: 0, overlayPosition01: position))
            guard let camera = resolver.cameraRect, resolver.stageRect.width > 0, resolver.stageRect.height > 0 else { return nil }
            let stage = resolver.stageRect
            return (
                position,
                Rect2(x: camera.x / stage.width, y: camera.y / stage.height, width: camera.width / stage.width, height: camera.height / stage.height),
                camera.shortestSide * project.style.cameraBorderRadiusRatio / stage.width
            )
        }
    }
}
