import AppKit
import RegravaCore

// Timeline item and track menus.

extension EditorModel {
    private static func speedLabel(_ speed: Double) -> String { String(format: "%g", speed) + "x" }
    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: Clip

    func sliceMenu(_ slice: Slice) -> [[MenuRow]] {
        let slices = project.slices
        guard let index = slices.firstIndex(where: { $0.id == slice.id }) else { return [] }
        let recording = project.recording
        var edits: [MenuRow] = [
            .command(.init(title: "Split at current time", icon: "scissors", shortcut: .plain("c")) { [weak self] in
                guard let self else { return }
                self.splitSlice(atPlayback: self.currentTimeMs)
            }),
        ]
        if index > 0 {
            edits.append(.command(.init(title: "Merge with previous", icon: "arrow.trianglehead.merge") { [weak self] in self?.mergeSlice(slice.id, with: .previous) }))
        }
        if index + 1 < slices.count {
            edits.append(.command(.init(title: "Merge with next", icon: "arrow.trianglehead.merge") { [weak self] in self?.mergeSlice(slice.id, with: .next) }))
        }
        if project.sliceHasStartTrim(index) || project.sliceHasEndTrim(index) {
            edits.append(.command(.init(title: "Reset trim", icon: "arrowshape.turn.up.left") { [weak self] in self?.removeSliceTrim(slice.id) }))
        }

        // Speeds by group: 1–2x, faster, slower; a checkmark on the current one.
        let speeds = Slice.speedOptions
        func speedRow(_ speed: Double) -> MenuRow {
            .command(.init(title: Self.speedLabel(speed), isChecked: abs(slice.timeScale - 1 / speed) < 1e-9) { [weak self] in self?.setSliceSpeed(slice.id, speed) })
        }
        var speed: [MenuRow] = [
            .submenu(title: "Set speed", icon: "gauge.with.dots.needle.67percent", groups: [
                speeds.filter { $0 >= 1 && $0 <= 2 }.map(speedRow),
                speeds.filter { $0 > 2 }.map(speedRow),
                speeds.filter { $0 < 1 }.map(speedRow),
            ]),
        ]
        if canApplySpeedToAll(from: slice.id) {
            speed.append(.command(.init(title: "Apply speed to all slices", icon: "gauge.with.dots.needle.67percent") { [weak self] in self?.applySpeedToAllSlices(from: slice.id) }))
        }

        var volumes: [MenuRow] = []
        if recording.hasMicrophone {
            volumes.append(.slider(title: "Microphone volume", value: slice.volume, range: 0...1, valueLabel: Self.percent) { [weak self] v in
                self?.updateSlice(slice.id) { $0.volume = v }
            })
        }
        if recording.hasSystemAudio {
            volumes.append(.slider(title: "System audio volume", value: slice.systemAudioVolume, range: 0...1, valueLabel: Self.percent) { [weak self] v in
                self?.updateSlice(slice.id) { $0.systemAudioVolume = v }
            })
        }
        if recording.hasExternalDeviceAudio {
            volumes.append(.slider(title: "External device audio volume", value: slice.externalDeviceAudioVolume, range: 0...1, valueLabel: Self.percent) { [weak self] v in
                self?.updateSlice(slice.id) { $0.externalDeviceAudioVolume = v }
            })
        }

        let cursor: [MenuRow] = [
            .command(.init(title: "Hide mouse cursor", icon: "eye.slash", isChecked: slice.hideCursor) { [weak self] in
                self?.updateSlice(slice.id) { $0.hideCursor.toggle() }
            }),
            .command(.init(title: "Disable smooth mouse movement", icon: "slash.circle", isChecked: slice.disableSmoothMouseMovement) { [weak self] in
                self?.updateSlice(slice.id) { $0.disableSmoothMouseMovement.toggle() }
            }),
        ]

        var destructive: [MenuRow] = []
        if slices.count > 1 {
            destructive.append(.command(.init(title: "Remove", icon: "trash", shortcut: .delete, isDestructive: true) { [weak self] in self?.removeSlice(slice.id) }))
        }
        if slices.count > 1 || slices.indices.contains(where: { project.sliceHasStartTrim($0) || project.sliceHasEndTrim($0) }) {
            destructive.append(.command(.init(title: "Reset trims and cuts for all slices", icon: "arrowshape.turn.up.left", isDestructive: true) { [weak self] in self?.resetAllSlices() }))
        }
        return [edits, speed, volumes, cursor, destructive]
    }

    // MARK: Zoom

    /// The selection when there is one, else the right-clicked zoom.
    private func zoomTargets(_ zoom: ZoomRange) -> [ZoomRange] {
        let selected = project.zooms.filter { selectedZoomIDs.contains($0.id) }
        return selected.isEmpty ? [zoom] : selected
    }

    func zoomMenu(_ zoom: ZoomRange) -> [[MenuRow]] {
        let targets = zoomTargets(zoom)
        let ids = Set(targets.map(\.id))
        let first = targets[0]
        let single = targets.count == 1
        func setPresentation(_ presentation: ZoomPresentation) {
            change { project in
                for i in project.zooms.indices where ids.contains(project.zooms[i].id) { project.zooms[i].presentation = presentation }
            }
            if let edited = project.zooms.first(where: { $0.id == first.id }) { LastEditedZoomStyle.capture(edited) }
        }
        func preview(_ presentation: ZoomPresentation) -> (Bool) -> Void {
            { [weak self] inside in
                self?.menuPreview = inside ? { project in
                    for i in project.zooms.indices where ids.contains(project.zooms[i].id) { project.zooms[i].presentation = presentation }
                } : nil
            }
        }
        let palette: [MenuRow] = [.palette([
            .init(title: "Classic", icon: "arrow.up.left.and.down.right.magnifyingglass", isSelected: first.presentation == .screen, preview: preview(.screen)) { setPresentation(.screen) },
            .init(title: "Loupe", icon: "sparkle.magnifyingglass", isSelected: first.presentation == .loupe, preview: preview(.loupe)) { setPresentation(.loupe) },
        ])]

        var level: [MenuRow] = [
            .slider(title: "Zoom level", value: first.scale, range: 1...4, valueLabel: Self.percent) { [weak self] v in
                self?.change { project in
                    for i in project.zooms.indices where ids.contains(project.zooms[i].id) { project.zooms[i].scale = v }
                }
                self?.rememberDefaultZoomLevel(v)
                if let edited = self?.project.zooms.first(where: { $0.id == first.id }) { LastEditedZoomStyle.capture(edited) }
            },
        ]
        if single {
            level.append(.command(.init(title: "Apply zoom level to all other zooms", icon: "plus.square") { [weak self] in
                self?.applyZoomLevelToAll(from: first.id)
                self?.showToast("Zoom level applied to all zooms")
            }))
        }

        var edits: [MenuRow] = [
            .command(.init(title: "Split zoom at current time", icon: "scissors", shortcut: .plain("c")) { [weak self] in
                guard let self else { return }
                // With several targets the clip is split instead.
                if single { self.splitZoom(first.id, at: self.currentSourceTimeMs) } else { self.splitSlice(atPlayback: self.currentTimeMs) }
            }),
        ]
        if single {
            edits.append(.command(.init(title: "Duplicate", icon: "plus", shortcut: .command("d")) { [weak self] in self?.duplicateZoom(first.id) }))
        }
        let someEnabled = project.zooms.contains { !$0.isDisabled }
        edits.append(.command(.init(
            title: "Disable", icon: "slash.circle", shortcut: .plain("d"), isChecked: first.isDisabled,
            alternate: someEnabled ? ("Disable all zoom ranges", { [weak self] in self?.setAllZooms(disabled: true) }) : nil
        ) { [weak self] in
            self?.change { project in
                for i in project.zooms.indices where ids.contains(project.zooms[i].id) { project.zooms[i].isDisabled.toggle() }
            }
        }))

        let clipboard: [MenuRow] = [
            .command(.init(title: "Copy zoom range", icon: "document.on.document", shortcut: .command("c")) { [weak self] in
                if single { self?.copyZoom(first.id) } else { self?.copyCurrentFrame() }
            }),
            .command(.init(title: "Cut to clipboard", shortcut: .command("x")) { [weak self] in
                if single { self?.cutZoom(first.id) }
            }),
        ]

        let remove: [MenuRow] = [
            .command(.init(
                title: "Remove", icon: "trash", shortcut: .delete, isDestructive: true,
                alternate: ("Remove all zoom ranges", { [weak self] in
                    guard let self else { return }
                    self.removeZooms(Set(self.project.zooms.map(\.id)))
                    self.selectedZoomIDs = []
                })
            ) { [weak self] in
                self?.removeZooms(ids)
                self?.selectedZoomIDs = []
            }),
        ]
        return [palette, level, edits, clipboard, remove]
    }

    func zoomTrackMenu() -> [[MenuRow]] {
        var rows: [MenuRow] = []
        if project.zooms.contains(where: { $0.isDisabled }) {
            rows.append(.command(.init(title: "Enable all zoom ranges", icon: "checkmark.circle") { [weak self] in self?.setAllZooms(disabled: false) }))
        }
        if project.zooms.contains(where: { !$0.isDisabled }) {
            rows.append(.command(.init(title: "Disable all zoom ranges", icon: "slash.circle") { [weak self] in self?.setAllZooms(disabled: true) }))
        }
        rows.append(.command(.init(title: "Restore default zoom ranges", icon: "arrow.clockwise") { [weak self] in self?.restoreDefaultZooms() }))
        let remove: [MenuRow] = [.command(.init(title: "Remove all zoom ranges", icon: "trash", isDestructive: true) { [weak self] in
            guard let self else { return }
            self.removeZooms(Set(self.project.zooms.map(\.id)))
        })]
        return [rows, remove]
    }

    // MARK: Camera layout

    func layoutMenu(_ layout: CameraLayoutRange) -> [[MenuRow]] {
        func set(_ type: CameraLayoutType) { updateLayout(layout.id) { $0.type = type } }
        func preview(_ type: CameraLayoutType) -> (Bool) -> Void {
            { [weak self] inside in
                self?.menuPreview = inside ? { project in
                    if let i = project.cameraLayouts.firstIndex(where: { $0.id == layout.id }) { project.cameraLayouts[i].type = type }
                } : nil
            }
        }
        let palette: [MenuRow] = [.palette([
            .init(title: "Overlay", icon: "square.grid.3x3", isSelected: layout.type == .cameraOverlay, preview: preview(.cameraOverlay)) { set(.cameraOverlay) },
            .init(title: "Cutout", icon: "person.and.background.dotted", isSelected: layout.type == .cutoutCamera, preview: preview(.cutoutCamera)) { set(.cutoutCamera) },
            .init(title: "Fullscreen", icon: "person.crop.rectangle", isSelected: layout.type == .fullscreenCamera, preview: preview(.fullscreenCamera)) { set(.fullscreenCamera) },
            .init(title: "Hide camera", icon: "macwindow", isSelected: layout.type == .screenOnly, preview: preview(.screenOnly)) { set(.screenOnly) },
        ])]
        let split: [MenuRow] = [.command(.init(title: "Split layout at current time", icon: "scissors", shortcut: .plain("c")) { [weak self] in
            guard let self else { return }
            self.splitLayout(layout.id, at: self.currentSourceTimeMs)
        })]
        let clipboard: [MenuRow] = [
            .command(.init(title: "Copy layout", icon: "document.on.document", shortcut: .command("c")) { [weak self] in self?.copyLayout(layout.id) }),
            .command(.init(title: "Cut to clipboard", shortcut: .command("x")) { [weak self] in self?.cutLayout(layout.id) }),
        ]
        let remove: [MenuRow] = [.command(.init(
            title: "Remove", icon: "trash", shortcut: .delete, isDestructive: true,
            alternate: ("Remove all layouts", { [weak self] in
                guard let self else { return }
                self.removeLayouts(Set(self.project.cameraLayouts.map(\.id)))
            })
        ) { [weak self] in self?.removeLayouts([layout.id]) })]
        return [palette, split, clipboard, remove]
    }

    func layoutTrackMenu() -> [[MenuRow]] {
        [[.command(.init(title: "Remove all layouts", icon: "trash", isDestructive: true) { [weak self] in
            guard let self else { return }
            self.removeLayouts(Set(self.project.cameraLayouts.map(\.id)))
        })]]
    }

    // MARK: Mask

    func maskMenu(_ mask: MaskRange) -> [[MenuRow]] {
        func set(_ type: MaskType) { updateMask(mask.id) { $0.type = type } }
        func preview(_ type: MaskType) -> (Bool) -> Void {
            { [weak self] inside in
                self?.menuPreview = inside ? { project in
                    if let i = project.masks.firstIndex(where: { $0.id == mask.id }) { project.masks[i].type = type }
                } : nil
            }
        }
        let palette: [MenuRow] = [.palette([
            .init(title: "Highlight", icon: "circle.rectangle.filled.pattern.diagonalline", isSelected: mask.type == .highlight, preview: preview(.highlight)) { set(.highlight) },
            .init(title: "Sensitive data", icon: "circle.filled.pattern.diagonalline.rectangle", isSelected: mask.type == .sensitiveData, preview: preview(.sensitiveData)) { set(.sensitiveData) },
        ])]
        let someEnabled = project.masks.contains { !$0.isDisabled }
        let edits: [MenuRow] = [
            .command(.init(title: "Split mask at current time", icon: "scissors", shortcut: .plain("c")) { [weak self] in
                guard let self else { return }
                self.splitMask(mask.id, at: self.currentSourceTimeMs)
            }),
            .command(.init(
                title: "Disable", icon: "slash.circle", shortcut: .plain("d"), isChecked: mask.isDisabled,
                alternate: someEnabled ? ("Disable all masks", { [weak self] in self?.setAllMasks(disabled: true) }) : nil
            ) { [weak self] in self?.updateMask(mask.id) { $0.isDisabled.toggle() } }),
        ]
        let clipboard: [MenuRow] = [
            .command(.init(title: "Copy mask", icon: "document.on.document", shortcut: .command("c")) { [weak self] in self?.copyMask(mask.id) }),
            .command(.init(title: "Cut to clipboard", shortcut: .command("x")) { [weak self] in self?.cutMask(mask.id) }),
        ]
        let remove: [MenuRow] = [.command(.init(
            title: "Remove", icon: "trash", shortcut: .delete, isDestructive: true,
            alternate: ("Remove all masks", { [weak self] in
                guard let self else { return }
                self.removeMasks(Set(self.project.masks.map(\.id)))
            })
        ) { [weak self] in self?.removeMasks([mask.id]) })]
        return [palette, edits, clipboard, remove]
    }

    func maskTrackMenu() -> [[MenuRow]] {
        var rows: [MenuRow] = []
        if project.masks.contains(where: { !$0.isDisabled }) {
            rows.append(.command(.init(title: "Disable all masks", icon: "slash.circle") { [weak self] in self?.setAllMasks(disabled: true) }))
        }
        let remove: [MenuRow] = [.command(.init(title: "Remove all masks", icon: "trash", isDestructive: true) { [weak self] in
            guard let self else { return }
            self.removeMasks(Set(self.project.masks.map(\.id)))
        })]
        return [rows, remove]
    }

    /// The zoom level becomes the default for new zooms after 1 s without changes.
    private func rememberDefaultZoomLevel(_ level: Double) {
        defaultZoomLevelTask?.cancel()
        defaultZoomLevelTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            Preferences.shared.defaultZoomLevel = level
        }
    }
}
