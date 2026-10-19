import AppKit
import RegravaCore
import SwiftUI

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Camera Layout

struct CameraLayoutPanel: View {
    @ObservedObject var editor: EditorModel

    private var project: Project { editor.project }
    private var layout: DefaultCameraLayout { project.defaultLayout }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSection(showsDivider: !project.camera.hide) {
                ToggleRow(icon: "eye.slash", title: "Hide camera", isOn: editor.binding(\.camera.hide))
            }
            if !project.camera.hide {
                SidebarSection {
                    NamedField(name: "Default layout") {
                        CameraLayoutTypePicker(
                            editor: editor,
                            types: CameraLayoutTypePicker.availableTypes(isDefaultLayout: true),
                            selection: editor.binding(\.defaultLayout.type)
                        )
                    }
                }
                SidebarSection {
                    switch layout.type {
                    case .splitScreen:
                        SplitLayoutOptionsView(editor: editor, options: editor.binding(\.defaultLayout.splitScreen))
                    case .cutoutCamera:
                        EmptyView()
                    default:
                        OverlayLayoutOptionsView(options: editor.binding(\.defaultLayout.cameraOverlay))
                    }
                }
                // "Avoid empty area" only when the fitted screen leaves the zoom area uncovered.
                if layout.type != .splitScreen && project.defaultLayoutResolver.hasUncoveredZoomArea {
                    SidebarSection {
                        ToggleRow(
                            title: "Avoid empty area",
                            description: "Will try to avoid showing too much empty space around the recording.",
                            isOn: editor.binding(\.style.avoidEmptyZoomArea)
                        )
                    }
                }
                let isCutout = layout.type == .cutoutCamera
                let isUnpaddedSplit = layout.type == .splitScreen && !layout.splitScreen.enablePadding
                if !isCutout && !isUnpaddedSplit {
                    SidebarSection(showsDivider: false) {
                        SliderField(
                            name: "Camera rounded corners",
                            value: editor.binding(\.style.cameraBorderRadiusRatio),
                            range: 0...0.5,
                            step: 0.0001,
                            resetValue: StyleConfig().cameraBorderRadiusRatio
                        )
                        if layout.type == .splitScreen && project.style.paddingRatio == 0 {
                            Callout(kind: .secondary, icon: nil, message: "For split screen layout, when padding is 0, the camera border radius will only be applied during zoom.")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Camera Style

/// Sharpen, mirror and the advanced camera delay. Color grading, crop and face tracking are
/// added as their processing is implemented.
struct CameraStylePanel: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSection {
                SliderField(
                    name: "Sharpen",
                    icon: "circle.hexagongrid",
                    value: editor.binding(\.camera.sharpen01),
                    range: 0...1,
                    step: 0.01,
                    preview: { $0 == 0 ? "Off" : percent($0) },
                    resetValue: 0
                )
            }
            SidebarSection(showsDivider: editor.project.recording.hasCamera) {
                ToggleRow(title: "Mirror horizontally", isOn: editor.binding(\.camera.mirror))
            }
            if editor.project.recording.hasCamera {
                NamedField(name: "Advanced", togglable: true) {
                    SliderField(
                        name: "Camera delay",
                        icon: "waveform.and.person.filled",
                        description: "If your lips look out of sync with your voice, raise it when they move after the words, lower it when they move before.",
                        value: editor.binding(\.camera.delayAdjustmentMs),
                        range: -200...200,
                        step: 5,
                        preview: { "\($0 > 0 ? "+" : "")\(Int($0.rounded())) ms" },
                        resetValue: 0
                    )
                }
            }
        }
    }
}

// MARK: - Layout type picker

/// Grid of layout tiles: a miniature of each layout over the wallpaper, its name below.
struct CameraLayoutTypePicker: View {
    @ObservedObject var editor: EditorModel
    var types: [CameraLayoutType]
    @Binding var selection: CameraLayoutType

    /// The default layout offers overlay and split (plus cutout where person segmentation is
    /// supported, which this app does not have); ranges also offer fullscreen and screen only.
    static func availableTypes(isDefaultLayout: Bool) -> [CameraLayoutType] {
        isDefaultLayout
            ? [.cameraOverlay, .splitScreen]
            : [.cameraOverlay, .splitScreen, .fullscreenCamera, .screenOnly]
    }

    var body: some View {
        if types.count > 1 {
            let columns = types.count > 4 ? 3 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gap(1)), count: columns), spacing: Theme.gap(1)) {
                ForEach(types, id: \.self) { type in
                    Button { selection = type } label: {
                        LayoutTile(type: type, split: editor.project.defaultLayout.splitScreen, wallpaperID: wallpaperID, isActive: type == selection)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var wallpaperID: String? {
        let background = editor.project.style.background
        return background.kind == .wallpaper ? background.systemName : nil
    }

    static func title(_ type: CameraLayoutType) -> String {
        switch type {
        case .screenOnly: "Only screen"
        case .splitScreen: "Split screen"
        case .cameraOverlay: "Camera overlay"
        case .fullscreenCamera: "Fullscreen camera"
        case .cutoutCamera: "Camera cutout"
        }
    }
}

private struct LayoutTile: View {
    var type: CameraLayoutType
    var split: SplitLayoutOptions
    var wallpaperID: String?
    var isActive: Bool
    @State private var wallpaper: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(1)) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let q = { (n: Double) -> Double in Double(side) * Double(Theme.gap(n)) / 100 }
                ZStack {
                    if let wallpaper {
                        Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    }
                    miniature(side: side, q: q)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: q(1.75)))
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: q(1.75) + 2).stroke(Theme.Colors.text.opacity(Theme.secondaryOpacity), lineWidth: 2).padding(-4)
                    }
                }
            }
            .aspectRatio(16.0 / 12, contentMode: .fit)
            Text(CameraLayoutTypePicker.title(type)).font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary)
        }
        .contentShape(Rectangle())
        .task(id: wallpaperID) {
            if let wallpaperID {
                wallpaper = await WallpaperThumbnails.shared.thumbnail(for: wallpaperID)
            } else {
                wallpaper = nil
            }
        }
    }

    @ViewBuilder
    private func miniature(side: Double, q: @escaping (Double) -> Double) -> some View {
        switch type {
        case .screenOnly:
            box(icon: "display", inverted: true, side: side, iconScale: 1.5, radius: q(1))
                .padding(q(0.5))
        case .splitScreen:
            // Screen and camera share the tile 1.75 : 1 (flex-grow), in the flipped order if set.
            GeometryReader { proxy in
                let vertical = split.direction == .vertical
                let total = vertical ? proxy.size.height : proxy.size.width
                let parts = split.flip ? ["camera", "screen"] : ["screen", "camera"]
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                layout {
                    ForEach(parts, id: \.self) { part in
                        let length = total * (part == "screen" ? 1.75 : 1) / 2.75
                        box(icon: part == "screen" ? "display" : "person", inverted: part == "screen", side: side, radius: 0)
                            .frame(width: vertical ? proxy.size.width : length, height: vertical ? length : proxy.size.height)
                    }
                }
            }
        case .cameraOverlay:
            box(icon: "display", inverted: true, side: side, radius: q(1))
                .padding(q(1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "person").font(.system(size: side * 0.175))
                        .padding(q(1.25))
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Colors.backgroundAccentHover))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.systemBorder, lineWidth: 1))
                        .padding(q(0.25))
                }
        case .fullscreenCamera:
            box(icon: "person", inverted: false, side: side, iconScale: 1.5, radius: q(1))
        case .cutoutCamera:
            box(icon: "display", inverted: true, side: side, radius: q(1)).padding(q(1))
        }
    }

    /// A centred icon on a light (`inverted`) or dark tile.
    private func box(icon: String, inverted: Bool, side: Double, iconScale: Double = 1, radius: Double) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(inverted ? Theme.Colors.text.opacity(0.85) : Theme.Colors.background.opacity(0.75))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.Colors.systemBorder, lineWidth: 1))
            .overlay(Image(systemName: icon).font(.system(size: side * 0.175 * iconScale)).foregroundStyle(inverted ? Theme.Colors.background : Theme.Colors.text))
    }
}

// MARK: - Overlay options

private let overlayAspectRatios: [(String, Double)] = [("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("3:4", 3.0 / 4), ("9:16", 9.0 / 16)]

struct OverlayLayoutOptionsView: View {
    @Binding var options: OverlayLayoutOptions
    var disablePositionPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            if !disablePositionPicker {
                NamedField(name: "Camera Position") {
                    OptionDotPicker(value: $options.position01, options: OptionDotPicker.eightPositions)
                }
            }
            NamedField(name: "Camera aspect ratio") {
                SegmentedPicker(
                    options: overlayAspectRatios.map(\.0),
                    label: { $0 },
                    selection: Binding(
                        get: { overlayAspectRatios.first { $0.1 == options.aspectRatio }?.0 ?? "" },
                        set: { name in if let ratio = overlayAspectRatios.first(where: { $0.0 == name })?.1 { options.aspectRatio = ratio } }
                    )
                )
            }
            SliderField(name: "Camera Size", value: $options.sizeRatio01, range: 0.1...0.75, step: 0.0001, preview: percent, resetValue: OverlayLayoutOptions().sizeRatio01)
            NamedField(name: "Camera size during zoom", icon: "magnifyingglass.circle", togglable: true) {
                VStack(alignment: .leading, spacing: Theme.gap(3)) {
                    ToggleRow(
                        title: "Make smaller during zoom",
                        description: "When zooming in, the camera will shrink to avoid covering the recording itself.",
                        isOn: Binding(get: { options.zoomedScale != 1 }, set: { options.zoomedScale = $0 ? 0.8 : 1 })
                    )
                    if options.zoomedScale != 1 {
                        SliderField(name: "Size during zoom", value: $options.zoomedScale, range: 0.25...0.8, preview: percent, resetValue: options.zoomedScale)
                    }
                }
            }
        }
    }
}

// MARK: - Split options

struct SplitLayoutOptionsView: View {
    @ObservedObject var editor: EditorModel
    @Binding var options: SplitLayoutOptions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            NamedField(name: "Split ratio") {
                SplitRatioPicker(ratio: $options.screenRatio01, isFlipped: options.flip)
            }
            ToggleRow(title: "Flip", description: "If enabled, the layout will be flipped.", isOn: $options.flip)
            ToggleRow(
                title: "Fill",
                description: options.enablePadding ? "Has padding around and between screen and camera" : "Split layout fills the entire screen.",
                labels: (off: "Fullscreen", on: "Padded"),
                isOn: $options.enablePadding
            )
            if options.enablePadding {
                SliderField(
                    name: "Padding",
                    value: editor.binding(\.style.paddingRatio),
                    range: 0...0.25,
                    preview: { String(format: "%.1f%%", $0 * 100) },
                    resetValue: 0.1
                )
                .help("Padding value is shared across all layouts in the project.")
            }
        }
    }
}

/// "Auto", ½ | ½ and ⅔ | ⅓ chips showing each side's share.
private struct SplitRatioPicker: View {
    @Binding var ratio: Double?
    var isFlipped: Bool

    private static let choices: [(screen: Double, labels: (screen: String, camera: String))] = [
        (1.0 / 2, ("½", "½")),
        (2.0 / 3, ("⅔", "⅓")),
    ]

    var body: some View {
        HStack(spacing: Theme.gap(1)) {
            chip(isSelected: ratio == nil, action: { ratio = nil }) {
                Text("Auto").font(Theme.Typo.copy).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(Self.choices, id: \.screen) { choice in
                chip(isSelected: ratio == choice.screen, action: { ratio = choice.screen }) {
                    GeometryReader { proxy in
                        let parts = isFlipped ? ["camera", "screen"] : ["screen", "camera"]
                        HStack(spacing: 0) {
                            ForEach(parts, id: \.self) { part in
                                let share = part == "screen" ? choice.screen : 1 - choice.screen
                                Text(part == "screen" ? choice.labels.screen : choice.labels.camera)
                                    .font(Theme.Typo.copy)
                                    .frame(width: proxy.size.width * share, height: proxy.size.height)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.Colors.hover))
                            }
                        }
                    }
                }
            }
        }
    }

    private func chip<Content: View>(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .padding(4)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Theme.Colors.active : Theme.Colors.lighterBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Theme.Colors.text.opacity(Theme.secondaryOpacity) : Theme.Colors.systemBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Discrete position picker

/// Dots at fixed relative positions inside a lighterBg box with 20 px padding. Each dot is
/// 20 px, primary.activeText at 10%; the active one is solid.
struct OptionDotPicker: View {
    @Binding var value: Vec2
    var options: [Vec2]

    static let eightPositions = [
        Vec2(0, 0), Vec2(0.5, 0), Vec2(1, 0), Vec2(0, 0.5), Vec2(1, 0.5), Vec2(0, 1), Vec2(0.5, 1), Vec2(1, 1),
    ]

    private var needsYAxis: Bool {
        guard let first = options.first, options.count > 1 else { return false }
        return options.contains { $0.y != first.y }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let isActive = option == value
                    Button { value = option } label: {
                        Circle()
                            .fill(Theme.Colors.primaryActiveText.opacity(isActive ? 1 : 0.1))
                            .frame(width: 20, height: 20)
                            .padding(15)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: option.x * proxy.size.width, y: option.y * proxy.size.height)
                }
            }
        }
        .frame(minHeight: needsYAxis ? 80 : 0)
        .frame(height: needsYAxis ? nil : 0)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: Theme.Boxes.control.radius).fill(Theme.Colors.lighterBg))
    }
}

// MARK: - Layout range inspector

/// The open layout range: "Disable layout", its type and position, the shared "Layout
/// settings" (which edit the default layout) and "Remove layout".
struct LayoutInspector: View {
    @ObservedObject var editor: EditorModel
    var layoutID: UUID

    private var layout: CameraLayoutRange? { editor.project.cameraLayouts.first { $0.id == layoutID } }

    var body: some View {
        if let layout {
            VStack(alignment: .leading, spacing: Theme.gap(3)) {
                ToggleRow(
                    title: "Disable layout",
                    isOn: Binding(get: { layout.isDisabled }, set: { v in editor.updateLayout(layoutID) { $0.isDisabled = v } })
                )
                if !layout.isDisabled {
                    VStack(alignment: .leading, spacing: 0) {
                        SidebarSection {
                            NamedField(name: "Layout type") {
                                CameraLayoutTypePicker(
                                    editor: editor,
                                    types: CameraLayoutTypePicker.availableTypes(isDefaultLayout: false),
                                    selection: Binding(get: { layout.type }, set: { v in editor.updateLayout(layoutID) { $0.type = v } })
                                )
                            }
                        }
                        switch layout.type {
                        case .cameraOverlay:
                            SidebarSection {
                                NamedField(name: "Camera Position") {
                                    OptionDotPicker(
                                        value: Binding(get: { layout.overlayPosition01 }, set: { v in editor.updateLayout(layoutID) { $0.overlayPosition01 = v } }),
                                        options: OptionDotPicker.eightPositions
                                    )
                                }
                            }
                            sharedSettings {
                                OverlayLayoutOptionsView(options: editor.binding(\.defaultLayout.cameraOverlay), disablePositionPicker: true)
                            }
                        case .splitScreen:
                            sharedSettings {
                                SplitLayoutOptionsView(editor: editor, options: editor.binding(\.defaultLayout.splitScreen))
                            }
                        default:
                            EmptyView()
                        }
                    }
                }
                RSButton(title: "Remove layout", icon: "trash", kind: .secondary) { editor.removeLayouts([layoutID]) }
            }
        }
    }

    /// "Layout settings" with the shared-properties badge.
    private func sharedSettings<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        SidebarSection {
            NamedField(
                name: "Layout settings",
                icon: "inset.filled.rectangle.and.person.filled",
                badge: ("cube.transparent", "Layout properties are shared across all layouts in the project.")
            ) {
                content()
            }
        }
    }
}
