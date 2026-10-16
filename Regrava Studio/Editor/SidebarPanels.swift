@preconcurrency import AVFoundation
import AppKit
import RegravaCore
import SwiftUI
import UniformTypeIdentifiers

private func percent(_ v: Double, decimals: Int = 0) -> String { String(format: "%.\(decimals)f%%", v * 100) }
private func degrees(_ v: Double) -> String { "\(Int(v.rounded()))°" }
private func seconds(_ ms: Double, decimals: Int = 1) -> String { String(format: "%.\(decimals)fs", ms / 1000) }

// MARK: - General

struct GeneralPanel: View {
    @ObservedObject var editor: EditorModel

    private var style: StyleConfig { editor.project.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSection {
                NamedField(name: "Background") {
                    SegmentedPicker(
                        options: BackgroundKind.allCases,
                        label: { $0.label },
                        // Wallpaper images and Unsplash are not bundled with this app.
                        isDisabled: { $0 == .wallpaper || $0 == .unsplash },
                        selection: editor.binding(\.style.background.kind)
                    )
                }
                backgroundDetails
            }
            SidebarSection {
                SliderField(name: "Padding", value: editor.binding(\.style.paddingRatio), range: 0...0.25, preview: { percent($0, decimals: 1) }, resetValue: 0.1)
                SliderField(name: "Screen rounded corners", value: editor.binding(\.style.cornerRadius), range: 0...128, step: 1, preview: { String(format: "%.1f", $0) }, resetValue: 16, suggestedValues: [0, 12, 16, 20, 26])
                ToggleRow(title: "Inset", description: "Add inset around the screen.", isOn: Binding(
                    get: { style.inset.isOn },
                    set: { on in editor.change { $0.style.inset = on ? .enabledDefault : InsetConfig(size: 0) } }
                ))
                if style.inset.isOn {
                    NestedPanel {
                        SliderField(name: "Inset size", value: editor.binding(\.style.inset.size), range: 0.125...24, step: 0.0001, preview: { String(format: "%.1f", $0) }, resetValue: 4)
                        NamedField(name: "Inset color") { ColorWellField(color: editor.binding(\.style.inset.color)) }
                        SliderField(name: "Inset opacity", value: editor.binding(\.style.inset.alpha), range: 0...1, step: 0.0001, resetValue: 0.25)
                        NamedField(name: "Inset position") {
                            DotPicker(point: editor.binding(\.style.inset.origin01), aspectRatio: 16.0 / 9) {
                                Theme.Colors.lighterBg
                            }
                        }
                    }
                }
            }
            SidebarSection(showsDivider: false) {
                SliderField(name: "Shadow", value: editor.binding(\.style.shadow.intensity), range: 0...0.6, step: 0.01, preview: { percent($0) }, resetValue: 0.3)
                if style.shadow.intensity > 0 {
                    SegmentedPicker(options: [false, true], label: { $0 ? "Directional" : "Classic" }, selection: editor.binding(\.style.shadow.isDirectional))
                    NamedField(name: "Advanced shadow settings", togglable: true) {
                        SliderField(name: "Shadow Distance", value: editor.binding(\.style.shadow.distance), range: 0...100, step: 1, resetValue: 25)
                        SliderField(name: "Shadow Angle", value: editor.binding(\.style.shadow.angle), range: 0...180, step: 1, preview: degrees, resetValue: 45)
                        SliderField(name: "Shadow Blur", value: editor.binding(\.style.shadow.blur), range: 0...30, step: 0.1, resetValue: 20)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var backgroundDetails: some View {
        switch style.background.kind {
        case .color:
            NamedField(name: "Background Color") {
                HStack {
                    ColorWellField(color: editor.binding(\.style.background.color))
                    RSIconButton(icon: "wand.and.sparkles", size: .small, tooltip: "Randomize background color") {
                        editor.change { $0.style.background.color = Self.randomColor() }
                    }
                }
            }
        case .gradient:
            NamedField(name: "Background Gradient") {
                HStack {
                    ColorWellField(color: editor.binding(\.style.background.gradientFrom))
                    ColorWellField(color: editor.binding(\.style.background.gradientTo))
                    RSIconButton(icon: "wand.and.sparkles", size: .small, tooltip: "Randomize gradient colors") {
                        editor.change {
                            $0.style.background.gradientFrom = Self.randomColor()
                            $0.style.background.gradientTo = Self.randomColor()
                        }
                    }
                }
            }
            SliderField(name: "Hue", icon: "paintpalette", value: hueBinding, range: 0...360, step: 1, preview: degrees)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(BackgroundConfig.gradientPresets.indices, id: \.self) { index in
                    let preset = BackgroundConfig.gradientPresets[index]
                    Button {
                        editor.change {
                            $0.style.background.gradientFrom = preset.0
                            $0.style.background.gradientTo = preset.1
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color(rgba: preset.0), Color(rgba: preset.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .image:
            NamedField(name: "Background Image") {
                BackgroundImagePicker(editor: editor)
            }
            SliderField(name: "Background blur", value: editor.binding(\.style.background.blur), range: 0...100, step: 0.1, preview: { String(format: "%.0fpx", $0) })
        case .wallpaper, .unsplash:
            EmptyView()
        }
    }

    /// Hue of the first stop; changing it rotates both stops by the same amount.
    private var hueBinding: Binding<Double> {
        Binding(
            get: { Double(NSColor(Color(rgba: style.background.gradientFrom)).usingColorSpace(.sRGB)?.hueComponent ?? 0) * 360 },
            set: { newHue in
                let current = Double(NSColor(Color(rgba: style.background.gradientFrom)).usingColorSpace(.sRGB)?.hueComponent ?? 0) * 360
                let delta = newHue - current
                editor.change(coalesce: "hue") {
                    $0.style.background.gradientFrom = Self.rotateHue($0.style.background.gradientFrom, by: delta)
                    $0.style.background.gradientTo = Self.rotateHue($0.style.background.gradientTo, by: delta)
                }
            }
        )
    }

    static func rotateHue(_ color: RGBA, by degrees: Double) -> RGBA {
        guard let c = NSColor(Color(rgba: color)).usingColorSpace(.sRGB) else { return color }
        var hue = Double(c.hueComponent) + degrees / 360
        hue -= floor(hue)
        let rotated = NSColor(hue: hue, saturation: c.saturationComponent, brightness: c.brightnessComponent, alpha: 1).usingColorSpace(.sRGB)!
        return RGBA(Double(rotated.redComponent), Double(rotated.greenComponent), Double(rotated.blueComponent))
    }

    static func randomColor() -> RGBA {
        let c = NSColor(hue: .random(in: 0...1), saturation: .random(in: 0.5...0.85), brightness: .random(in: 0.6...0.95), alpha: 1).usingColorSpace(.sRGB)!
        return RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

/// Drop zone / button: "Click to select, drop image, or press ⌘V while hovering." (.png/.jpg/.jpeg)
private struct BackgroundImagePicker: View {
    @ObservedObject var editor: EditorModel
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Theme.gap(1)) {
                if let name = editor.project.style.background.imageFileName,
                   let image = NSImage(contentsOf: editor.bundleURL.appendingPathComponent(name)) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(height: 90).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Image(systemName: "photo").font(.system(size: 18))
                Text("Click to select, drop image, or press ⌘V while hovering.")
                    .font(Theme.Typo.label)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.Colors.hover : Theme.Colors.lighterBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.Colors.systemBorder))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in use(url) } }
            }
            return true
        }
        .onPasteCommand(of: [.fileURL, .png, .jpeg, .tiff]) { _ in
            if let image = NSImage(pasteboard: .general), let data = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-background.png")
                try? png.write(to: url)
                use(url)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    /// Copies the image into the project folder.
    private func use(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else { return }
        let name = "background-\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try FileManager.default.copyItem(at: url, to: editor.bundleURL.appendingPathComponent(name))
            editor.change { $0.style.background.imageFileName = name }
        } catch {
            Dialogs.error("Could not use this image: \(error.localizedDescription)")
        }
    }
}

extension Color {
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

// MARK: - Cursor

struct CursorPanel: View {
    @ObservedObject var editor: EditorModel

    private var cursor: CursorConfig { editor.project.cursor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cursor.hide {
                hideToggle
            } else {
                SidebarSection {
                    SliderField(name: "Cursor size", value: editor.binding(\.cursor.size), range: 16...128, preview: { String(format: "%.1f", $0) }, resetValue: 48)
                }
                SidebarSection {
                    ToggleRow(title: "Hide cursor if not moving", isOn: Binding(
                        get: { cursor.hideNotMovingAfterMs != nil },
                        set: { on in editor.change { $0.cursor.hideNotMovingAfterMs = on ? 2000 : nil } }
                    ))
                    if let after = cursor.hideNotMovingAfterMs {
                        NestedPanel {
                            SliderField(name: "Hide not moving cursor after", value: Binding(
                                get: { after },
                                set: { v in editor.change(coalesce: "hide-after") { $0.cursor.hideNotMovingAfterMs = v } }
                            ), range: 500...5000, step: 100, preview: { seconds($0) }, resetValue: 2000)
                        }
                    }
                    ToggleRow(title: "Loop cursor position", description: "Near the end of the video, cursor will move back to its initial position", isOn: Binding(
                        get: { cursor.loopPositionBeforeEndMs != nil },
                        set: { on in editor.change { $0.cursor.loopPositionBeforeEndMs = on ? 1000 : nil } }
                    ))
                    if let loop = cursor.loopPositionBeforeEndMs {
                        NestedPanel {
                            SliderField(
                                name: "Loop cursor position duration",
                                description: "How long before the end of the recording to reset position of the mouse",
                                value: Binding(
                                    get: { loop },
                                    set: { v in
                                        editor.change(coalesce: "loop") { $0.cursor.loopPositionBeforeEndMs = v }
                                        editor.seek(to: editor.durationMs - v)
                                    }
                                ),
                                range: 1000...4000, step: 100, preview: { seconds($0, decimals: 0) }, resetValue: 1000
                            )
                        }
                    }
                    hideToggle
                }
                SidebarSection {
                    NamedField(name: "Click effect") {
                        SegmentedPicker(
                            options: [nil, ClickEffect.circle, .ripple],
                            label: { $0 == nil ? "None" : $0 == .circle ? "Circle" : "Ripple" },
                            selection: editor.binding(\.cursor.clickEffect)
                        )
                    }
                }
                SidebarSection {
                    NamedField(name: "Rotation", togglable: true) {
                        SliderField(name: "Rotate cursor", value: editor.binding(\.cursor.baseRotation), range: -180...180, step: 1, preview: degrees, resetValue: 0)
                    }
                }
                SidebarSection(showsDivider: false) {
                    NamedField(name: "Advanced", togglable: true) {
                        if cursor.loopPositionBeforeEndMs == nil {
                            SliderField(
                                name: "Stop cursor movement at the end of the video",
                                description: "Near the end of the video, the last mouse movement often leads to clicking \"Stop Recording,\" which you might not want to be visible. Adjust how long before the end of the video the mouse cursor will stop moving.",
                                value: Binding(
                                    get: { cursor.stopMovementInLastPartMs },
                                    set: { v in
                                        editor.change(coalesce: "stop-movement") { $0.cursor.stopMovementInLastPartMs = v }
                                        editor.seek(to: editor.durationMs - v)
                                    }
                                ),
                                range: 0...5000, step: 50, preview: { seconds($0, decimals: 0) }, resetValue: 0
                            )
                        }
                        ToggleRow(
                            title: "Remove cursor shakes",
                            description: "If you use some accessibility apps that can control your mouse, it is possible those apps will cause sudden, short movements of your mouse. This option allows trying to detect and remove them.",
                            isOn: Binding(
                                get: { cursor.removeShakeThreshold != 0 },
                                set: { on in editor.change { $0.cursor.removeShakeThreshold = on ? 500 : 0 } }
                            )
                        )
                        if cursor.removeShakeThreshold != 0 {
                            RSSlider(value: editor.binding(\.cursor.removeShakeThreshold), range: 100...2000, step: 20, preview: { String(Int($0)) }, resetValue: 500)
                        }
                    }
                }
            }
        }
    }

    private var hideToggle: some View {
        ToggleRow(icon: "eye.slash", title: "Hide cursor", isOn: editor.binding(\.cursor.hide))
    }
}

// MARK: - Animations

struct AnimationsPanel: View {
    @ObservedObject var editor: EditorModel

    /// UI reset value for both springs.
    private let resetSpring = SpringConfig.screen

    var body: some View {
        SidebarSection(showsDivider: false) {
            SpringEditor(
                name: "Screen animation style",
                presets: SpringPreset.screen,
                config: Binding(get: { editor.project.animation.screenSpring }, set: { v in editor.change { $0.animation.screenSpring = v ?? .screen } }),
                resetConfig: resetSpring
            )
            SpringEditor(
                name: "Cursor animation style",
                presets: SpringPreset.cursor,
                config: Binding(get: { editor.project.animation.mouseSpring }, set: { v in editor.change { $0.animation.mouseSpring = v } }),
                resetConfig: resetSpring
            )
        }
    }
}

/// Row of vertical pills (icon over label); hovering previews the description and a dot demo.
private struct SpringEditor: View {
    var name: String
    var presets: [SpringPreset]
    @Binding var config: SpringConfig?
    var resetConfig: SpringConfig
    @State private var hovered: SpringPreset?

    private var selected: SpringPreset? { presets.first { $0.config == config } }

    var body: some View {
        NamedField(name: name) {
            VStack(alignment: .leading, spacing: Theme.gap(1)) {
                HStack(spacing: Theme.gap(0)) {
                    ForEach(presets, id: \.name) { preset in
                        let isSelected = preset == selected
                        Button { config = preset.config } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.icon).font(.system(size: 16))
                                Text(preset.name).font(Theme.Typo.label)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Theme.Colors.active : hovered == preset ? Theme.Colors.hover : Theme.Colors.lighterBg))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.white.opacity(0.25) : .clear))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.text.opacity(isSelected ? 1 : Theme.secondaryOpacity))
                        .onHover { hovered = $0 ? preset : (hovered == preset ? nil : hovered) }
                    }
                }
                if let description = (hovered ?? selected)?.description {
                    Text(description).font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let demo = hovered?.config {
                    SpringDemo(config: demo).frame(height: 14)
                }
                if config != resetConfig {
                    RSButton(title: "Reset", kind: .secondary, size: .small) { config = resetConfig }
                }
            }
        }
    }
}

/// A 10 px dot moving back and forth with the spring.
private struct SpringDemo: View {
    var config: SpringConfig

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                Circle().fill(Theme.Colors.primary).frame(width: 10, height: 10)
                    .offset(x: (geometry.size.width - 10) * position(at: context.date), y: 2)
            }
        }
    }

    /// Animates 0→1 then 1→0, 1.6 s each way.
    private func position(at date: Date) -> Double {
        let period = 1.6
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period * 2)
        let goingRight = t < period
        var spring = SpringValue(goingRight ? 0 : 1)
        spring.advance(toward: goingRight ? 1 : 0, config: config, milliseconds: (goingRight ? t : t - period) * 1000)
        return spring.value
    }
}

// MARK: - Zoom inspector

struct ZoomInspector: View {
    @ObservedObject var editor: EditorModel
    var zoomID: UUID
    @State private var still: NSImage?

    private var zoom: ZoomRange? { editor.project.zooms.first { $0.id == zoomID } }

    var body: some View {
        if let zoom {
            VStack(alignment: .leading, spacing: 0) {
                SidebarSection {
                    NamedField(name: "Zoom style") {
                        SegmentedPicker(
                            options: ZoomPresentation.allCases,
                            label: { $0 == .screen ? "Classic" : "Glass Loupe" },
                            icon: { $0 == .screen ? "arrow.up.left.and.arrow.down.right.square.fill" : "magnifyingglass.circle.fill" },
                            // The Glass Loupe effect is not rendered by this app yet.
                            isDisabled: { $0 == .loupe },
                            size: .hero,
                            isWide: true,
                            selection: editor.zoomBinding(zoomID, \.presentation)
                        )
                    }
                    if zoom.presentation == .screen {
                        NestedPanel {
                            ToggleRow(title: "Instant animation", description: "If enabled, the zoom will be applied instantly without any animation.", isOn: editor.zoomBinding(zoomID, \.isInstant))
                        }
                    }
                }
                SidebarSection {
                    NamedField(name: "Zoom position") {
                        VStack(alignment: .leading, spacing: Theme.gap(1)) {
                            SegmentedPicker(
                                options: ZoomMode.allCases,
                                label: { $0 == .auto ? "Auto" : "Manual" },
                                icon: { $0 == .auto ? "wand.and.sparkles" : "scope" },
                                description: { $0 == .auto ? "Zoomed camera will automatically try to keep the mouse cursor visible." : "Drag the dot to choose what to zoom in on.\n⌘-drag to turn off snapping." },
                                descriptionMinLines: 2,
                                isWide: true,
                                selection: editor.zoomBinding(zoomID, \.mode)
                            )
                            if zoom.mode == .manual {
                                DotPicker(point: editor.zoomBinding(zoomID, \.manualTarget), aspectRatio: editor.project.recording.videoSize.aspectRatio) {
                                    if let still { Image(nsImage: still).resizable() } else { Theme.Colors.lighterBg }
                                }
                                .task(id: zoom.startMs) { still = await stillFrame(at: zoom.startMs) }
                            }
                        }
                    }
                    SliderField(
                        name: "Zoom level",
                        description: "How close to zoom on the cursor during this zoom phase",
                        value: editor.zoomBinding(zoomID, \.scale),
                        range: 1...4,
                        step: 0.01,
                        preview: { percent($0) },
                        resetValue: Preferences.shared.defaultZoomLevel ?? 2
                    )
                }
                SidebarSection(showsDivider: false) {
                    NamedField(name: "Advanced", togglable: true) {
                        ToggleRow(
                            title: "Start animation early",
                            description: "The zoom starts animating before its range so it is fully zoomed in when the playhead reaches it. Applies to every zoom in this project.",
                            isOn: editor.binding(\.animation.startsZoomEarly)
                        )
                    }
                    RSButton(title: "Remove zoom", icon: "trash", kind: .secondary) { editor.removeZooms([zoomID]) }
                }
            }
        }
    }

    /// Still of the raw recording at the zoom's start (for the manual target picker).
    private func stillFrame(at ms: Double) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: editor.videoURL))
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let image = try? await generator.image(at: CMTime(seconds: ms / 1000, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
