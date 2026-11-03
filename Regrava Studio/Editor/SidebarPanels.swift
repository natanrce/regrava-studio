@preconcurrency import AVFoundation
import AppKit
import RegravaCore
import RegravaRender
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
                        // Unsplash search is not available in this app.
                        isDisabled: { $0 == .unsplash },
                        selection: editor.binding(\.style.background.kind)
                    )
                }
                backgroundDetails
            }
            SidebarSection {
                SliderField(name: "Padding", value: editor.binding(\.style.paddingRatio), range: 0...0.25, step: 0.001, preview: { percent($0, decimals: 1) }, resetValue: 0.1)
                SplitPaddingNote(editor: editor, resolver: editor.resolver)
                // Only with padding; hidden for device recordings (`changeBorderRadius`).
                if style.paddingRatio > 0 && editor.project.canChangeScreenBorderRadius {
                    SliderField(name: "Screen rounded corners", value: editor.binding(\.style.cornerRadius), range: 0...128, step: 1, preview: { String(format: "%.1f", $0) }, resetValue: 16, suggestedValues: [0, 12, 16, 20, 26])
                }
                if editor.project.canChangeScreenInset {
                    ToggleRow(title: "Inset", description: "Add inset around the screen.", isOn: Binding(
                        get: { style.inset.isOn },
                        set: { on in
                            editor.change {
                                if on {
                                    let preferred = InsetPreference.stored
                                    $0.style.inset = preferred.size > 0 ? preferred : .enabledDefault
                                } else {
                                    $0.style.inset.size = 0
                                }
                            }
                        }
                    ))
                }
                if style.inset.isOn && editor.project.canChangeScreenInset {
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
            SidebarSection {
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
            // Privacy, the last section.
            SidebarSection(showsDivider: false) { PrivacySection(editor: editor) }
        }
        .onAppear { InsetPreference.remember(style.inset) }
        .onChange(of: style.inset) { _, inset in InsetPreference.remember(inset) }
    }

    @ViewBuilder
    private var backgroundDetails: some View {
        switch style.background.kind {
        case .color:
            NamedField(name: "Background Color") {
                HStack {
                    ColorWellField(color: editor.binding(\.style.background.color))
                    RSIconButton(icon: "wand.and.sparkles", size: .small, tooltip: "Randomize background color") {
                        editor.change { $0.style.background.color = BackgroundPalette.colors(1)[0] }
                    }
                }
            }
        case .gradient:
            NamedField(name: "Background Gradient") {
                HStack {
                    ColorWellField(color: editor.binding(\.style.background.gradientFrom))
                    ColorWellField(color: editor.binding(\.style.background.gradientTo))
                    RSIconButton(icon: "wand.and.sparkles", size: .small, tooltip: "Randomize gradient colors") {
                        editor.change { $0.style.background.gradient = BackgroundPalette.randomGradient() }
                    }
                }
            }
            SliderField(name: "Hue", icon: "paintpalette", value: hueBinding, range: 0...360, step: 1, preview: degrees)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(BackgroundConfig.gradientPresets.indices, id: \.self) { index in
                    let preset = BackgroundConfig.gradientPresets[index]
                    PickerTile(isSelected: style.background.gradientStops == preset) {
                        LinearGradient(colors: preset.map { Color(rgba: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .onTapGesture { editor.change { $0.style.background.gradientStops = preset } }
                }
            }
        case .image:
            NamedField(name: "Background Image") {
                BackgroundImagePicker(editor: editor)
            }
            SliderField(name: "Background blur", value: editor.binding(\.style.background.blur), range: 0...100, step: 0.1, preview: { String(format: "%.0fpx", $0) })
        case .wallpaper:
            NamedField(name: "Wallpaper") {
                WallpaperPicker(selection: editor.binding(\.style.background.systemName))
            }
            SliderField(name: "Background blur", value: editor.binding(\.style.background.blur), range: 0...100, step: 0.1, preview: { String(format: "%.0fpx", $0) })
        case .unsplash:
            EmptyView()
        }
    }

    /// OKLCH hue of the first stop; changing it rotates every stop by the same amount.
    private var hueBinding: Binding<Double> {
        Binding(
            get: { style.background.gradient.hueDegrees },
            set: { newHue in editor.change { $0.style.background.gradient = $0.style.background.gradient.withHue(newHue) } }
        )
    }
}

/// The last inset settings in use ("preferred-inset-settings"), restored when the inset is
/// turned on again.
enum InsetPreference {
    private static let key = "preferred-inset-settings"

    static var stored: InsetConfig {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(InsetConfig.self, from: $0) } ?? .enabledDefault
    }

    static func remember(_ inset: InsetConfig) {
        guard inset.size > 0, let data = try? JSONEncoder().encode(inset) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Under Padding while the layout at the playhead (or the default one) is a split screen
/// without padding; only this note redraws with the playhead.
private struct SplitPaddingNote: View {
    @ObservedObject var editor: EditorModel
    @EnvironmentObject private var clock: PlaybackClock
    var resolver: TimeResolver

    var body: some View {
        let project = editor.project
        let range = project.enabledLayout(atSource: resolver.playbackToSource(clock.currentTimeMs))
        if (range?.type ?? project.defaultLayout.type) == .splitScreen && !project.defaultLayout.splitScreen.enablePadding {
            Callout(kind: .secondary, icon: nil, message: "Padding isn't applied because the current split-screen layout has padding turned off.", link: ("Edit layout", {
                if let range, range.type == .splitScreen {
                    // The range's inspector shows the split layout's settings.
                    editor.setSidebarItem(.layout(range.id))
                } else {
                    editor.openSidebar(.cameraLayout)
                }
            }))
        }
    }
}

/// Drop zone / button: "Click to select, drop image, or press ⌘V while hovering." (.png/.jpg/.jpeg)
private struct BackgroundImagePicker: View {
    @ObservedObject var editor: EditorModel
    @State private var hovered = false

    /// Decoded images by path: each copied image gets a new file name, so a path never changes
    /// content, and the panel redraws on every editor change.
    private static let images = NSCache<NSURL, NSImage>()

    private static func image(at url: URL) -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Theme.gap(1)) {
                if let name = editor.project.style.background.imageFileName,
                   let image = Self.image(at: editor.bundleURL.appendingPathComponent(name)) {
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
        let _ = CursorToggleMemory.note(cursor)
        VStack(alignment: .leading, spacing: 0) {
            HiddenCursorClipNote(editor: editor, resolver: editor.resolver)
            if cursor.hide {
                hideToggle
            } else {
                SidebarSection {
                    SliderField(name: "Cursor size", value: editor.binding(\.cursor.size), range: 16...128, preview: { String(format: "%.1f", $0) }, resetValue: 48)
                    CursorStylePicker(editor: editor)
                    ToggleRow(
                        title: "Always use pointer cursor",
                        description: "Don't change cursor, even if selecting text, etc.",
                        isOn: editor.binding(\.cursor.alwaysUseDefault)
                    )
                }
                SidebarSection {
                    ToggleRow(title: "Hide cursor if not moving", isOn: Binding(
                        get: { cursor.hideNotMovingAfterMs != nil },
                        set: { on in editor.change { $0.cursor.hideNotMovingAfterMs = on ? CursorToggleMemory.hideNotMovingAfterMs : nil } }
                    ))
                    if let after = cursor.hideNotMovingAfterMs {
                        NestedPanel {
                            SliderField(name: "Hide not moving cursor after", value: Binding(
                                get: { after },
                                set: { v in editor.change { $0.cursor.hideNotMovingAfterMs = v } }
                            ), range: 500...5000, step: 100, preview: { seconds($0) }, resetValue: 2000)
                        }
                    }
                    ToggleRow(title: "Loop cursor position", description: "Near the end of the video, cursor will move back to its initial position", isOn: Binding(
                        get: { cursor.loopPositionBeforeEndMs != nil },
                        set: { on in editor.change { $0.cursor.loopPositionBeforeEndMs = on ? CursorToggleMemory.loopPositionBeforeEndMs : nil } }
                    ))
                    if let loop = cursor.loopPositionBeforeEndMs {
                        NestedPanel {
                            SliderField(
                                name: "Loop cursor position duration",
                                description: "How long before the end of the recording to reset position of the mouse",
                                value: Binding(
                                    get: { loop },
                                    set: { v in
                                        editor.change { $0.cursor.loopPositionBeforeEndMs = v }
                                        editor.seek(to: editor.durationMs - v)
                                    }
                                ),
                                range: 1000...4000, step: 100, preview: { seconds($0) }, resetValue: 1000
                            )
                        }
                    }
                    hideToggle
                }
                SidebarSection {
                    NamedField(name: "Click effect") {
                        SegmentedPicker(
                            options: [nil, ClickEffect.Kind.circle, .ripple],
                            label: { $0 == nil ? "None" : $0 == .circle ? "Circle" : "Ripple" },
                            selection: Binding(
                                get: { cursor.clickEffect?.type },
                                set: { kind in editor.change { $0.cursor.clickEffect = kind.map { ClickEffect(type: $0) } } }
                            )
                        )
                    }
                    ClickSoundField(editor: editor)
                }
                SidebarSection {
                    NamedField(name: "Rotation", togglable: true) {
                        SliderField(name: "Rotate cursor", value: editor.binding(\.cursor.baseRotation), range: -180...180, step: 1, preview: degrees, resetValue: 0)
                        NamedField(name: "Rotate while moving", icon: "cursorarrow.motionlines.click", description: "How the cursor rotates as it chases the mouse.") {
                            SegmentedPicker(
                                options: CursorRotationMode.allCases,
                                label: { $0 == .velocity ? "Tilt" : "Follow" },
                                description: {
                                    $0 == .velocity
                                        ? "Leans with fast horizontal movement, settling back upright at rest."
                                        : "Points along the direction of travel, like pulled on a leash - and keeps its bearing at rest."
                                },
                                selection: editor.binding(\.cursor.rotationMode)
                            )
                        }
                        if cursor.rotationMode == .velocity {
                            SliderField(
                                name: "Tilt amount",
                                description: "How strongly horizontal movement leans the cursor.",
                                value: editor.binding(\.cursor.rotateOnXMovementRatio),
                                range: 0...2,
                                resetValue: 0.5
                            )
                        }
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
                                        editor.change { $0.cursor.stopMovementInLastPartMs = v }
                                        editor.seek(to: editor.durationMs - v)
                                    }
                                ),
                                range: 0...5000, step: 50, preview: { seconds($0) }, resetValue: 0
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
                            SliderField(name: "Remove cursor shakes threshold", value: editor.binding(\.cursor.removeShakeThreshold), range: 100...2000, step: 20, preview: { String(Int($0.rounded())) }, resetValue: 500)
                        }
                        ToggleRow(
                            title: "Optimize cursor changes",
                            description: "Regrava Studio will try to minimize rapid cursor changes (eg when quickly moving over some elements) when this option is enabled.",
                            isOn: editor.binding(\.cursor.optimizeOriginalTypes)
                        )
                        ToggleRow(
                            title: "Keep cursor in sync with hovers",
                            description: "When something lights up under the moving mouse, like a menu item or a button, the cursor gets there just in time, setting off a little earlier or moving a little faster, so the highlight never shows before the cursor does.",
                            isOn: editor.binding(\.cursor.followRecordedPositionOnHover)
                        )
                    }
                }
            }
        }
    }

    private var hideToggle: some View {
        ToggleRow(icon: "eye.slash", title: "Hide cursor", isOn: editor.binding(\.cursor.hide))
    }
}

/// The last durations used by the cursor toggles in this session, picked up from whatever
/// project shows them; switching a toggle back on restores them.
@MainActor
enum CursorToggleMemory {
    private static var lastHideNotMovingAfterMs = 2000.0
    private static var lastLoopPositionBeforeEndMs = 1000.0

    static func note(_ cursor: CursorConfig) {
        if let ms = cursor.hideNotMovingAfterMs, ms != 0 { lastHideNotMovingAfterMs = ms }
        if let ms = cursor.loopPositionBeforeEndMs, ms != 0 { lastLoopPositionBeforeEndMs = ms }
    }

    static var hideNotMovingAfterMs: Double { lastHideNotMovingAfterMs }
    static var loopPositionBeforeEndMs: Double { lastLoopPositionBeforeEndMs }
}

/// Shown while the clip under the playhead hides the cursor; only this note redraws with the
/// playhead.
private struct HiddenCursorClipNote: View {
    @ObservedObject var editor: EditorModel
    @EnvironmentObject private var clock: PlaybackClock
    var resolver: TimeResolver

    var body: some View {
        let project = editor.project
        if let index = project.sliceIndex(atSource: resolver.playbackToSource(clock.currentTimeMs)), project.slices[index].hideCursor {
            let id = project.slices[index].id
            SidebarSection {
                Callout(icon: nil, message: "Cursor is hidden in this part of the recording, so you will not see changes you make to it.")
                RSButton(title: "Open clip settings", kind: .secondary) { editor.setSidebarItem(.slice(id)) }
            }
        }
    }
}

// MARK: - Animations

struct AnimationsPanel: View {
    @ObservedObject var editor: EditorModel

    /// UI reset value for both springs.
    private let resetSpring = SpringConfig.screen

    var body: some View {
        SidebarSection {
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
        // Section 2: 0–1, percent preview, no reset.
        SidebarSection(showsDivider: false) {
            SliderField(
                name: "Motion blur",
                description: "Elements that are moving will have a cinematic motion blur effect applied",
                value: Binding(
                    get: { editor.project.animation.motionBlurAmount },
                    set: { v in editor.change { $0.animation.motionBlurAmount = v } }
                ),
                range: 0...1,
                preview: { "\(Int(($0 * 100).rounded()))%" }
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
                // Shown once the value differs from the default; a full-width secondary button.
                if config != resetConfig {
                    RSButton(title: "Reset", kind: .secondary, isWide: true) { config = resetConfig }
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
                            size: .hero,
                            isWide: true,
                            selection: editor.zoomBinding(zoomID, \.presentation)
                        )
                    }
                    NestedPanel {
                        if zoom.presentation == .screen {
                            ToggleRow(title: "Instant animation", description: "If enabled, the zoom will be applied instantly without any animation.", isOn: editor.zoomBinding(zoomID, \.isInstant))
                        } else {
                            // "Glass Loupe size".
                            SliderField(
                                name: "Glass Loupe size",
                                value: editor.zoomBinding(zoomID, \.loupeOptions.radius01),
                                range: 0.25...0.75,
                                preview: { "\(Int(($0 * 100).rounded()))%" },
                                resetValue: LoupeOptions().radius01
                            )
                        }
                    }
                }
                SidebarSection {
                    NamedField(name: "Zoom position") {
                        VStack(alignment: .leading, spacing: Theme.gap(1)) {
                            // Auto needs a recorded mouse (not on iPhone or iPad).
                            if editor.project.usesAutomaticZooms {
                                SegmentedPicker(
                                    options: ZoomMode.allCases,
                                    label: { $0 == .auto ? "Auto" : "Manual" },
                                    icon: { $0 == .auto ? "wand.and.sparkles" : "scope" },
                                    description: { $0 == .auto ? "Zoomed camera will automatically try to keep the mouse cursor visible." : "Drag the dot to choose what to zoom in on.\n⌘-drag to turn off snapping." },
                                    descriptionMinLines: 2,
                                    isWide: true,
                                    selection: editor.zoomBinding(zoomID, \.mode)
                                )
                            }
                            if zoom.mode == .manual {
                                DotPicker(point: editor.zoomBinding(zoomID, \.manualTarget), aspectRatio: editor.project.croppedVideoSize.aspectRatio) {
                                    if let still { Image(nsImage: still).resizable() } else { Theme.Colors.lighterBg }
                                }
                                .task(id: zoom.startMs) { still = await stillFrame(at: zoom.startMs) }
                            }
                        }
                    }
                    SliderField(
                        name: "Zoom level",
                        description: "How close to zoom on the cursor during this zoom phase",
                        value: Binding(
                            get: { zoom.scale },
                            set: { level in
                                editor.updateZoom(zoomID) { $0.scale = level }
                                editor.rememberDefaultZoomLevel(level)
                            }
                        ),
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
        guard var image = try? await generator.image(at: CMTime(seconds: ms / 1000, preferredTimescale: 600)).image else { return nil }
        // The target point is in the crop, so is the still.
        let c = editor.project.screenCrop01
        if let cropped = image.cropping(to: CGRect(x: c.x * Double(image.width), y: c.y * Double(image.height), width: c.width * Double(image.width), height: c.height * Double(image.height)).integral) { image = cropped }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// MARK: - Slice inspector

struct SliceInspector: View {
    @ObservedObject var editor: EditorModel
    var sliceID: UUID

    private var slice: Slice? { editor.project.slices.first { $0.id == sliceID } }

    var body: some View {
        if let slice {
            VStack(alignment: .leading, spacing: 0) {
                let recording = editor.project.recording
                if recording.hasMicrophone || recording.hasSystemAudio || recording.hasExternalDeviceAudio {
                    SidebarSection {
                        if recording.hasMicrophone {
                            SliderField(
                                name: "Microphone volume",
                                icon: "microphone",
                                value: Binding(get: { slice.volume }, set: { v in editor.updateSlice(sliceID) { $0.volume = v } }),
                                range: 0...1,
                                step: 0.01,
                                preview: { "\(Int(($0 * 100).rounded()))%" }
                            )
                        }
                        if recording.hasSystemAudio {
                            SliderField(
                                name: "System audio volume",
                                icon: "hifispeaker",
                                value: Binding(get: { slice.systemAudioVolume }, set: { v in editor.updateSlice(sliceID) { $0.systemAudioVolume = v } }),
                                range: 0...1,
                                step: 0.01,
                                preview: { "\(Int(($0 * 100).rounded()))%" }
                            )
                        }
                        if recording.hasExternalDeviceAudio {
                            SliderField(
                                name: "External device audio volume",
                                icon: "iphone.gen1.radiowaves.left.and.right",
                                value: Binding(get: { slice.externalDeviceAudioVolume }, set: { v in editor.updateSlice(sliceID) { $0.externalDeviceAudioVolume = v } }),
                                range: 0...1,
                                step: 0.01,
                                preview: { "\(Int(($0 * 100).rounded()))%" }
                            )
                        }
                    }
                }
                SidebarSection {
                    NamedField(name: "Speed") {
                        VStack(alignment: .leading, spacing: Theme.gap(1)) {
                            SegmentedPicker(
                                options: Slice.speedOptions,
                                label: { String(format: "%gx", $0) },
                                selection: Binding(get: { slice.speed }, set: { editor.setSliceSpeed(sliceID, $0) })
                            )
                            RSButton(title: "Apply speed to all slices", icon: "gauge.with.dots.needle.67percent", kind: .secondary) {
                                editor.applySpeedToAllSlices(from: sliceID)
                            }
                            .disabled(!editor.canApplySpeedToAll(from: sliceID))
                        }
                    }
                }
                if recording.hasCursor {
                    SidebarSection {
                        NamedField(name: "Cursor settings", description: "Change appearance of mouse cursor in this part of the recording.", togglable: true) {
                            ToggleRow(title: "Hide cursor", isOn: Binding(
                                get: { slice.hideCursor },
                                set: { v in editor.updateSlice(sliceID) { $0.hideCursor = v } }
                            ))
                            if !slice.hideCursor {
                                ToggleRow(
                                    title: "Disable smooth mouse movement",
                                    description: "This is useful, for example, when recording drop-down menus, where precise alignment is required.",
                                    isOn: Binding(
                                        get: { slice.disableSmoothMouseMovement },
                                        set: { v in editor.updateSlice(sliceID) { $0.disableSmoothMouseMovement = v } }
                                    )
                                )
                            }
                        }
                    }
                }
                SidebarSection(showsDivider: false) {
                    RSButton(title: "Remove slice", icon: "trash", kind: .secondary) { editor.removeSlice(sliceID) }
                        .disabled(editor.project.slices.count < 2)
                }
            }
        }
    }
}

// MARK: - Mask inspector

/// Shown while the playhead is outside the mask; only this note redraws with the playhead.
private struct MaskOutsideNote: View {
    @EnvironmentObject private var clock: PlaybackClock
    var resolver: TimeResolver
    var mask: MaskRange
    var focus: () -> Void

    var body: some View {
        if !mask.contains(resolver.playbackToSource(clock.currentTimeMs)) {
            VStack(alignment: .leading, spacing: Theme.gap(1)) {
                Text("Preview is showing different part of the recording than the one covered by the mask.")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                RSButton(title: "Focus the timeline on the mask", kind: .secondary, action: focus)
            }
            .padding(.bottom, Theme.gap(3))
        }
    }
}

/// Disabled while the playhead already sits on the mask start; only this button redraws with
/// the playhead.
private struct MaskStartFocusButton: View {
    @EnvironmentObject private var clock: PlaybackClock
    var resolver: TimeResolver
    var mask: MaskRange
    var focus: () -> Void

    var body: some View {
        // Where focusing puts the playhead (seeks land on 60 fps frames).
        let frame = 1000.0 / 60
        let target = (resolver.sourceToPlayback(mask.startMs) / frame).rounded() * frame
        RSButton(title: "Focus the timeline on the mask start", kind: .secondary, action: focus)
            .disabled(abs(clock.currentTimeMs - target) < 0.001)
            .tooltip("Start is source of the mask")
    }
}

struct MaskInspector: View {
    @ObservedObject var editor: EditorModel
    var maskID: UUID

    private var mask: MaskRange? { editor.project.masks.first { $0.id == maskID } }

    var body: some View {
        if let mask {
            VStack(alignment: .leading, spacing: 0) {
                MaskOutsideNote(resolver: editor.resolver, mask: mask) { focus(mask, at: mask.startMs + mask.durationMs / 2) }
                SidebarSection {
                    NamedField(name: "Mask type") {
                        VStack(alignment: .leading, spacing: Theme.gap(1)) {
                            SegmentedPicker(
                                options: MaskType.allCases,
                                label: { $0 == .sensitiveData ? "Sensitive Data" : "Highlight" },
                                isWide: true,
                                selection: Binding(get: { mask.type }, set: { v in editor.updateMask(maskID) { $0.type = v } })
                            )
                            if mask.type == .sensitiveData {
                                Callout(icon: "timeline.selection", message: "Make sure the mask covers the entire part of the timeline where sensitive data is present.")
                            }
                            MaskStartFocusButton(resolver: editor.resolver, mask: mask) { focus(mask, at: mask.startMs) }
                            if mask.type == .highlight {
                                SliderField(
                                    name: "Highlight mask opacity",
                                    value: Binding(
                                        get: { mask.highlightMaskOpacity },
                                        set: { v in editor.updateMask(maskID) { $0.highlightMaskOpacity = v } }
                                    ),
                                    range: 0.1...0.9,
                                    preview: { "\(Int(($0 * 100).rounded()))%" },
                                    resetValue: 0.5
                                )
                                if editor.project.masks.count > 1 {
                                    RSButton(title: "Apply to all masks", kind: .secondary) { editor.applyHighlightOpacityToAllMasks(from: maskID) }
                                }
                            }
                        }
                    }
                }
                SidebarSection {
                    ToggleRow(
                        title: "Disable",
                        description: "When disabled, the mask will not be applied, but it will still be present in the timeline.",
                        isOn: Binding(get: { mask.isDisabled }, set: { v in editor.updateMask(maskID) { $0.isDisabled = v } })
                    )
                }
                SidebarSection(showsDivider: false) {
                    RSButton(title: "Remove mask", icon: "trash", kind: .secondary) { editor.removeMasks([maskID]) }
                }
            }
        }
    }

    private func focus(_ mask: MaskRange, at sourceMs: Double) {
        editor.seek(to: editor.project.resolver.sourceToPlayback(sourceMs))
    }
}

// MARK: - Audio

struct AudioPanel: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var preview = BackgroundAudioPreview()
    /// Always starts on Lo-Fi; not persisted.
    @State private var category: BackgroundAudioCategory = .loFi
    @State private var libraryTracks: [URL] = []

    private var audio: AudioConfig { editor.project.audio }
    private var recording: RecordingInfo { editor.project.recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recording.hasMicrophone {
                // A titled section: the title in tertiary label type.
                SidebarSection(title: "Microphone") {
                    Group {
                        VStack(alignment: .leading, spacing: Theme.gap(3)) {
                            ToggleRow(title: "Mute microphone", isOn: editor.binding(\.audio.muteMicrophone))
                            // Shown when not muted and more than one mode is supported.
                            let presets = EditorModel.supportedMicrophonePresets
                            if !audio.muteMicrophone && presets.count > 1 {
                                NamedField(name: "Microphone audio mode") {
                                    SegmentedPicker(
                                        options: presets,
                                        label: { $0.label },
                                        description: { $0.detail },
                                        progress: { editor.microphoneRenderProgress[$0] },
                                        isPaused: { editor.pausedMicrophoneRenders.contains($0) },
                                        badge: { $0.badge },
                                        selection: Binding(
                                            get: { audio.microphoneAudioPreset },
                                            set: { preset in
                                                if preset == audio.microphoneAudioPreset {
                                                    editor.toggleMicrophoneRender(preset)
                                                } else {
                                                    editor.change { $0.audio.microphoneAudioPreset = preset }
                                                    // Also the default for new projects.
                                                    Preferences.shared.microphoneAudioPreset = preset
                                                }
                                            }
                                        )
                                    )
                                }
                            }
                            // Muted with the webcam still shown: the video plays silent.
                            if recording.hasCamera && !editor.project.camera.hide && audio.muteMicrophone {
                                VStack(alignment: .leading, spacing: Theme.gap(2)) {
                                    Callout(message: "Your selfie camera video is still visible, but it will be muted. Consider hiding it in camera settings.")
                                    RSButton(title: "Hide camera", kind: .secondary) { editor.change { $0.camera.hide = true } }
                                }
                            } else if audio.muteMicrophone {
                                Callout(icon: "speaker.slash.fill", message: "Microphone is muted.")
                            }
                        }
                    }
                }
            }
            if recording.hasSystemAudio {
                // A titled section: the title in tertiary label type.
                SidebarSection(title: "System audio") {
                    Group {
                        VStack(alignment: .leading, spacing: Theme.gap(3)) {
                            ToggleRow(title: "Mute system audio", isOn: editor.binding(\.audio.muteSystemAudio))
                            if audio.muteSystemAudio {
                                Callout(icon: "speaker.slash.fill", message: "System audio is muted.")
                            }
                        }
                    }
                }
            }
            if recording.hasExternalDeviceAudio {
                // A titled section: the title in tertiary label type.
                SidebarSection(title: "External device audio") {
                    Group {
                        VStack(alignment: .leading, spacing: Theme.gap(3)) {
                            ToggleRow(title: "Mute external device audio", isOn: editor.binding(\.audio.muteExternalDeviceAudio))
                            if audio.muteExternalDeviceAudio {
                                Callout(icon: "speaker.slash.fill", message: "External device audio is muted.")
                            }
                        }
                    }
                }
            }
            SidebarSection(title: "Background audio", showsDivider: false) {
                Group {
                    VStack(alignment: .leading, spacing: Theme.gap(2)) {
                        SegmentedPicker(
                            options: BackgroundAudioCategory.allCases,
                            label: { $0.title },
                            size: .small,
                            selection: $category
                        )
                        let tracks = category == .userLibrary ? libraryTracks : BundledSounds.backgroundTracks(category: category.rawValue)
                        if !tracks.isEmpty {
                            // Selected = the track whose display name matches the stored file's. A
                            // scrollable segmented row; selected = the track whose display name matches
                            // the stored file's.
                            SegmentedPicker(
                                options: tracks,
                                label: { BackgroundAudioLibrary.displayName($0.lastPathComponent, maxLength: 20) },
                                size: .small,
                                selection: Binding(
                                    get: { tracks.first { BackgroundAudioLibrary.displayName($0.lastPathComponent) == BackgroundAudioLibrary.displayName(audio.backgroundAudioFileName ?? "") } ?? URL(fileURLWithPath: "/") },
                                    set: { pick($0) }
                                )
                            )
                        }
                        if category == .userLibrary {
                            if libraryTracks.isEmpty {
                                Callout(kind: .secondary, icon: nil, message: "Add background audio tracks to your library folder to access them here")
                            }
                            RSButton(title: "Open audio library folder", icon: "folder", kind: .secondary) { BackgroundAudioLibrary.reveal() }
                        }
                        Rectangle().fill(Theme.Colors.lighterBg).frame(height: 1).padding(.vertical, 4)
                        if let name = audio.backgroundAudioFileName {
                            RSButton(
                                title: (preview.isPlaying ? "Stop " : "Play ") + BackgroundAudioLibrary.displayName(name, maxLength: 20),
                                icon: preview.isPlaying ? "stop.circle" : "play.circle",
                                kind: .subtle,
                                isWide: true
                            ) { preview.toggle(url: assetURL(name), volume: audio.backgroundAudioVolume) }
                            ToggleRow(title: "Mute background audio", isOn: editor.binding(\.audio.muteBackgroundAudio))
                            if !audio.muteBackgroundAudio {
                                SliderField(
                                    name: "Background audio volume",
                                    icon: "hifispeaker",
                                    value: Binding(
                                        get: { audio.backgroundAudioVolume },
                                        set: { v in
                                            editor.change { $0.audio.backgroundAudioVolume = (v * 100).rounded() / 100 }
                                            preview.setVolume(v)
                                        }
                                    ),
                                    range: 0...1,
                                    step: 0.01,
                                    preview: { "\(Int(($0 * 100).rounded()))%" },
                                    resetValue: AudioConfig().backgroundAudioVolume
                                )
                            }
                            RSButton(title: "Remove background audio", icon: "hifispeaker.badge.minus", kind: .secondary, isWide: true) { remove(name) }
                        } else {
                            RSButton(title: "Add background audio", icon: "hifispeaker.badge.plus", kind: .subtle, isWide: true) { addFromFile() }
                        }
                    }
                }
            }
        }
        .onAppear { libraryTracks = BackgroundAudioLibrary.tracks() }
        .onDisappear { preview.stop() }
    }

    private func assetURL(_ name: String) -> URL {
        ProjectStore.assetsURL(bundle: editor.bundleURL).appendingPathComponent(name)
    }

    /// Copies a track into the project and plays it (`playOnChange`).
    private func use(_ source: URL) {
        guard let name = BackgroundAudioLibrary.copy(source, intoProject: editor.bundleURL) else { return }
        editor.change { $0.audio.backgroundAudioFileName = name }
        if !editor.isPlaying { preview.play(url: assetURL(name), volume: audio.backgroundAudioVolume) }
    }

    private func pick(_ track: URL) {
        guard track.path != "/" else { return }
        use(track)
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    private func remove(_ name: String) {
        preview.stop()
        try? FileManager.default.removeItem(at: assetURL(name))
        editor.change { $0.audio.backgroundAudioFileName = nil }
    }
}

// MARK: - Click sound

/// Plays the chosen set's click.wav at the current volume (`audio.playSoundAsset`).
@MainActor
enum ClickSoundPreview {
    private static var player: AVAudioPlayer?

    static func play(_ set: ClickSoundSet, volume: Double) {
        guard let url = BundledSounds.click(set, .click), let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = Float(volume)
        player.play()
        self.player = player
    }
}

/// Shown while paused over a part faster than 2× (`sourceRate > 2`); only this note redraws
/// with the playhead.
private struct ClickSoundSpeedWarning: View {
    @EnvironmentObject private var clock: PlaybackClock
    var isPlaying: Bool
    var playbackRate: Double
    var resolver: TimeResolver

    var body: some View {
        if !isPlaying, resolver.speed(atSource: resolver.playbackToSource(clock.currentTimeMs)) * playbackRate > 2 {
            Callout(message: "Sound will not be played for parts with a playback speed greater than 2x.")
        }
    }
}

struct ClickSoundField: View {
    @ObservedObject var editor: EditorModel
    @State private var isPreviewBusy = false

    private var audio: AudioConfig { editor.project.audio }

    var body: some View {
        NamedField(name: "Click sound") {
            VStack(alignment: .leading, spacing: Theme.gap(2)) {
                SegmentedPicker(
                    options: [nil] + ClickSoundSet.allCases.map { Optional($0) },
                    label: { $0?.label ?? "None" },
                    selection: Binding(
                        get: { audio.clickSoundEffect },
                        set: { value in
                            editor.change { $0.audio.clickSoundEffect = value }
                            // Auto-preview when a set is chosen.
                            if let value { ClickSoundPreview.play(value, volume: audio.clickSoundEffectVolume) }
                        }
                    )
                )
                ClickSoundSpeedWarning(isPlaying: editor.isPlaying, playbackRate: editor.playbackRate, resolver: editor.resolver)
                if let set = audio.clickSoundEffect {
                    SliderField(
                        name: "Click sound volume",
                        icon: "computermouse",
                        value: Binding(
                            get: { audio.clickSoundEffectVolume },
                            set: { v in editor.change { $0.audio.clickSoundEffectVolume = (v * 10).rounded() / 10 } }
                        ),
                        range: 0...1,
                        step: 0.1,
                        preview: { "\(Int(($0 * 100).rounded()))%" },
                        resetValue: 0.25
                    )
                    RSButton(title: "Play click sound preview", icon: "speaker.wave.2", kind: .secondary) {
                        guard !isPreviewBusy else { return }
                        ClickSoundPreview.play(set, volume: audio.clickSoundEffectVolume)
                        isPreviewBusy = true
                        Task { try? await Task.sleep(nanoseconds: 300_000_000); isPreviewBusy = false }
                    }
                    .disabled(isPreviewBusy)
                }
            }
        }
    }
}

// MARK: - Cursor style

/// Last variant picked per set and type, on this Mac (`cursorSetVariantPreference_v2`).
enum CursorVariantPreference {
    private static let key = "cursorSetVariantPreference_v2"

    static func variants(for setID: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key)?[setID] as? [String: String]) ?? [:]
    }

    static func remember(setID: String, type: String, entryID: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var forSet = all[setID] as? [String: String] ?? [:]
        forSet[type] = entryID
        all[setID] = forSet
        UserDefaults.standard.set(all, forKey: key)
    }
}

struct CursorStylePicker: View {
    @ObservedObject var editor: EditorModel

    private var choice: CursorSetChoice { editor.project.cursor.set }

    var body: some View {
        let sets = CursorSets.pickable()
        let selectedSet = CursorSets.all.first { $0.id == choice.id }
        NamedField(name: "Cursor style") {
            VStack(alignment: .leading, spacing: Theme.gap(2)) {
                CursorTileStrip(
                    options: sets.compactMap { set in representative(of: set).map { (set, $0) } },
                    size: 32,
                    selectedID: { $0.0.id == choice.id },
                    entry: { $0.1 },
                    variants: { option in option.0.variantTypes.flatMap { option.0.cursors[$0] ?? [] } },
                    onPick: { option in
                        editor.change { $0.cursor.set = CursorSetChoice(id: option.0.id, variants: CursorVariantPreference.variants(for: option.0.id)) }
                    }
                )
                if let selectedSet, !selectedSet.variantTypes.isEmpty {
                    NamedField(name: "Variant") {
                        VStack(alignment: .leading, spacing: Theme.gap(1)) {
                            ForEach(selectedSet.variantTypes, id: \.self) { type in
                                let entries = selectedSet.cursors[type] ?? []
                                let current = entries.first { $0.id == choice.variants[type] } ?? entries.first
                                CursorTileStrip(
                                    options: entries,
                                    size: 24,
                                    selectedID: { $0 == current },
                                    entry: { $0 },
                                    variants: { _ in [] },
                                    onPick: { entry in
                                        var updated = choice
                                        updated.variants[type] = entry.id
                                        CursorVariantPreference.remember(setID: selectedSet.id, type: type, entryID: entry.id)
                                        editor.change { $0.cursor.set = updated }
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// The preferred variant of the pointer (or pointing hand…), else its first.
    private func representative(of set: CursorSet) -> CursorSetEntry? {
        let entries = set.representativeEntries
        guard let type = entries.first?.type else { return nil }
        let preferred = CursorVariantPreference.variants(for: set.id)[type]
        return entries.first { $0.id == preferred } ?? entries.first
    }
}

/// A horizontally scrolling row of square tiles that keeps the selected one centred.
struct CursorTileStrip<Option>: View {
    var options: [Option]
    var size: CGFloat
    var selectedID: (Option) -> Bool
    var entry: (Option) -> CursorSetEntry
    var variants: (Option) -> [CursorSetEntry]
    var onPick: (Option) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.gap(1)) {
                    ForEach(options.indices, id: \.self) { i in
                        let option = options[i]
                        CursorTile(entry: entry(option), variants: variants(option), size: size, isSelected: selectedID(option)) { onPick(option) }
                            .id(i)
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, -24)
            .onAppear { if let i = options.firstIndex(where: selectedID) { proxy.scrollTo(i, anchor: .center) } }
            .onChange(of: options.firstIndex(where: selectedID)) { _, i in
                if let i { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(i, anchor: .center) } }
            }
        }
    }
}

/// The image contained in a square (macos art scaled 1.75×); hovering an unselected tile
/// cycles its variants after 100 ms, then every second.
struct CursorTile: View {
    var entry: CursorSetEntry
    var variants: [CursorSetEntry]
    var size: CGFloat
    var isSelected: Bool
    var action: () -> Void
    @State private var hovered = false
    @State private var shown: CursorSetEntry?
    @State private var cycle: Task<Void, Never>?

    var body: some View {
        let current = shown ?? entry
        Button(action: action) {
            Group {
                if let image = current.image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(entry.setID == "macos" ? 1.75 : 1)
            .id(current.url)
            .transition(.opacity.combined(with: .scale(scale: 0.2)))
            .padding(8 * size / 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.Colors.hover : Theme.Colors.lighterBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Theme.Colors.primaryActiveText : Theme.Colors.systemBorder.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: current.url)
        .onHover { inside in
            hovered = inside
            cycle?.cancel()
            shown = nil
            guard inside, !isSelected, !variants.isEmpty else { return }
            cycle = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                var index = variants.firstIndex(of: entry) ?? -1
                while !Task.isCancelled {
                    index = (index + 1) % variants.count
                    shown = variants[index]
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected { cycle?.cancel(); shown = nil }
        }
    }
}


// MARK: - Privacy

/// "Hide sensitive data" and "Hide faces", each with its "Review Before Sharing" warning, and the
/// custom phrases under the first.
private struct PrivacySection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let processing = editor.project.processing
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            ToggleRow(icon: "lock.fill", title: "Hide sensitive data", description: "Covers emails, phone numbers, card numbers and keys shown in the recording",
                      isOn: editor.binding(\.processing.autoMaskSensitiveData))
            if processing.autoMaskSensitiveData {
                ReviewWarning()
                CustomPhrasesField(editor: editor)
            }
            ToggleRow(icon: "face.dashed.fill", title: "Hide faces", description: "Blurs people's faces shown in the recording, like avatars and video calls",
                      isOn: editor.binding(\.processing.autoMaskFaces))
            if processing.autoMaskFaces { ReviewWarning() }
        }
    }
}

/// Shown under each toggle that is on.
private struct ReviewWarning: View {
    var body: some View {
        Callout(kind: .warning, icon: "exclamationmark.triangle.fill", title: "Review Before Sharing",
                message: "Some private details may still be visible in parts of your recording. Watch it in full before you share it.")
    }
}

/// A button while there are no phrases, else a text area saved on blur when the parsed list changed.
private struct CustomPhrasesField: View {
    @ObservedObject var editor: EditorModel
    @State private var isEditing = false
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        let stored = editor.project.processing.sensitiveDataCustomPhrases
        if stored.isEmpty && !isEditing {
            RSButton(title: "Add custom phrases", icon: "plus", kind: .secondary) {
                isEditing = true
                DispatchQueue.main.async { focused = true }
            }
            .fixedSize()
        } else {
            NamedField(name: "Custom phrases", description: "Names, clients or other words, separated by commas") {
                ZStack(alignment: .topLeading) {
                    if (draft ?? stored.joined(separator: ", ")).isEmpty {
                        Text("Jane Appleseed, Acme Inc.")
                            .font(Theme.Typo.controlCopy)
                            .foregroundStyle(Theme.Colors.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { draft ?? stored.joined(separator: ", ") }, set: { draft = $0 }))
                        .font(Theme.Typo.controlCopy)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 44)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                isEditing = false
                if let text = draft {
                    draft = nil
                    let parsed = ProcessingConfig.parsePhrases(text)
                    if parsed.joined(separator: "\n") != stored.joined(separator: "\n") {
                        editor.change { $0.processing.sensitiveDataCustomPhrases = parsed }
                    }
                }
            }
        }
    }
}
