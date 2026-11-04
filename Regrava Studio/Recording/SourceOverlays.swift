import AppKit
import Combine
import RegravaCapture
import SwiftUI

/// Full-screen source overlays, one per display.
@MainActor
final class SourceOverlayController {
    private weak var coordinator: RecordingCoordinator?
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var keyMonitor: Any?
    let area = AreaPickerState()

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        guard let coordinator else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, panels[id] == nil else { continue }
            let panel = OverlayPanel(screen: screen)
            let view = SourceOverlayView(coordinator: coordinator, area: area, displayID: id)
            panel.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            panel.orderFrontRegardless()
            panels[id] = panel
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event) == true ? nil : event
            }
        }
    }

    func hide() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Enter starts, Escape cancels, arrows move/resize the area (⇧ = 10 px, ⌘ = resize).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let coordinator else { return false }
        switch event.keyCode {
        case 36, 76:
            if coordinator.selection != nil, coordinator.selectionError == nil {
                coordinator.startPressed()
                return true
            }
        case 53:
            coordinator.escape()
            return true
        case 123, 124, 125, 126:
            guard case let .area(id, rect) = coordinator.selection else { return false }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            var updated = rect
            if event.modifierFlags.contains(.command) {
                updated.size.width = max(updated.width + dx, 1)
                updated.size.height = max(updated.height + dy, 1)
            } else {
                updated = updated.offsetBy(dx: dx, dy: dy)
            }
            coordinator.setArea(displayID: id, rect: AreaPickerState.clamp(updated, to: CGDisplayBounds(id).size))
            return true
        default:
            break
        }
        return false
    }
}

/// Transparent, borderless overlay covering one screen, kept out of recordings.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .recordingOverlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Cover color: rgba(0,0,0,0.4) when "Highlight Recorded Area" is on, else clear.
@MainActor
private func coverColor() -> Color {
    Preferences.shared.recordingAreaCover ? Color.black.opacity(0.4) : Color.black.opacity(0.001)
}

private let sourceHighlight = Theme.Colors.sourceHighlight

struct SourceOverlayView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var area: AreaPickerState
    var displayID: CGDirectDisplayID

    private var display: DisplayInfo? { coordinator.displays.first { $0.id == displayID } }

    var body: some View {
        Group {
            switch coordinator.sourceType {
            case .display:
                if let display { DisplayPickerOverlay(coordinator: coordinator, display: display) }
            case .window:
                if let display { WindowPickerOverlay(coordinator: coordinator, display: display) }
            case .area:
                AreaPickerOverlay(coordinator: coordinator, state: area, displayID: displayID)
            case .device:
                DeviceRecordingOverlay(coordinator: coordinator)
            default:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
    }
}

// MARK: - Display

private struct DisplayPickerOverlay: View {
    @ObservedObject var coordinator: RecordingCoordinator
    var display: DisplayInfo
    @State private var hovered = false

    private var isSelected: Bool { coordinator.selection == .display(display) }

    var body: some View {
        ZStack {
            coverColor()
            sourceHighlight.opacity(isSelected || hovered ? 0.25 : 0)
                .animation(.easeOut(duration: 0.15), value: isSelected || hovered)
            // Every display card shows its Start button; hovering makes it the one Enter starts.
            SourceCard(title: display.label, meta: "\(Int(display.frame.width))×\(Int(display.frame.height)) • \(display.refreshRate)FPS") {
                StartRecordingButton(coordinator: coordinator, target: .display(display), isActive: hovered)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // Clicking the picked display keeps it picked.
        .onTapGesture { if !isSelected { coordinator.selection = .display(display) } }
    }
}

/// Centered title (hero 32) + meta (12) + accessory, max width 320, text shadow.
private struct SourceCard<Accessory: View>: View {
    var title: String
    var meta: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: Theme.gap(2)) {
            Text(title).font(Theme.Typo.hero).multilineTextAlignment(.center)
            if let meta { Text(meta).font(Theme.Typo.label).opacity(0.8) }
            accessory()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.75), radius: 2, x: 1, y: 1)
        .frame(maxWidth: 320)
        .animation(.easeOut(duration: 0.1), value: meta)
    }
}

// MARK: - Window

private struct WindowPickerOverlay: View {
    @ObservedObject var coordinator: RecordingCoordinator
    var display: DisplayInfo

    private var windows: [WindowInfo] {
        let all = coordinator.windows.filter { $0.frame.intersects(display.frame) && !coordinator.ignoredWindowIDs.contains($0.id) }
        if case .window(let selected) = coordinator.selection { return all.filter { $0.id == selected.id } }
        return all
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            coverColor()
                .contentShape(Rectangle())
                .onTapGesture { coordinator.selection = nil }
                .contextMenu { Button("Record entire display") { coordinator.recordEntireDisplay(display) } }
            // Back-most first so the front-most window wins hit testing.
            ForEach(windows.reversed()) { window in
                WindowHighlight(coordinator: coordinator, window: window, display: display)
            }
            if windows.isEmpty {
                VStack(spacing: Theme.gap(2)) {
                    WiggleIcon(name: "macwindow", size: 32, isWiggling: true)
                    Text("No windows to select").font(Theme.Typo.titleMedium)
                    RSButton(title: "Record entire display", kind: .secondaryInline) { coordinator.recordEntireDisplay(display) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct WindowHighlight: View {
    @ObservedObject var coordinator: RecordingCoordinator
    var window: WindowInfo
    var display: DisplayInfo
    @State private var hovered = false

    private var isSelected: Bool { coordinator.selection == .window(window) }
    private var local: CGRect { window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
    /// "Ignore this window" is offered for a window exactly the display's size.
    private var isDisplaySized: Bool {
        PickerRules.isFullscreen(window: window.frame, display: display.frame)
    }

    var body: some View {
        let active = isSelected || hovered
        ZStack {
            // The window's own corner radius.
            RoundedRectangle(cornerRadius: window.borderRadius)
                .fill(sourceHighlight.opacity(0.25))
                .opacity(active ? 1 : 0)
                .animation(.easeOut(duration: active ? 0.15 : 0.3), value: active)
            RoundedRectangle(cornerRadius: window.borderRadius)
                .strokeBorder(sourceHighlight.opacity(isSelected ? 0.5 : 0), lineWidth: 3)
            if active {
                VStack(spacing: Theme.gap(2)) {
                    if let path = window.appPath {
                        Image(nsImage: FileIcons.icon(forFile: path))
                            .resizable()
                            .frame(width: 96, height: 96)
                    }
                    SourceCard(title: window.appName.replacingOccurrences(of: ".app", with: ""), meta: "\(Int(window.frame.width)) × \(Int(window.frame.height))") {
                        StartRecordingButton(coordinator: coordinator, target: .window(window), isActive: active)
                    }
                }
                VStack {
                    Spacer()
                    HStack(spacing: Theme.gap(1)) {
                        SuggestionChip(title: "Adjust recording area") { coordinator.adjustArea(to: window) }
                        if isDisplaySized {
                            SuggestionChip(title: "Ignore this window") {
                                coordinator.ignoredWindowIDs.insert(window.id)
                                coordinator.selection = nil
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(width: local.width, height: local.height)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { coordinator.toggleWindow(window) }
        .rightClickMenu { contextMenu() }
        .offset(x: local.minX, y: local.minY)
    }
}

extension WindowHighlight {
    /// "Adjust recording area...", "Select window ▸", then Bring to front, Ignore and Reset.
    fileprivate func contextMenu() -> MenuBuilder {
        let coordinator = self.coordinator
        let window = self.window
        let menu = MenuBuilder()
        menu.group("default")
        menu.item("Adjust recording area...") { coordinator.adjustArea(to: window) }
        menu.group("manual")
        menu.submenu("Select window") { WindowSelectMenu.add(to: $0, coordinator: coordinator) }
        menu.group("system")
        menu.item("Bring to front") { WindowActions.bringToFront(window) }
        menu.group("ignore")
        menu.item("Ignore this window") { coordinator.ignoredWindowIDs.insert(window.id) }
        if !coordinator.ignoredWindowIDs.isEmpty {
            menu.item("Reset ignored windows") { coordinator.ignoredWindowIDs.removeAll() }
        }
        return menu
    }
}

/// 22 px chip, radius 6, padding 2×8, text@0.2 background.
private struct SuggestionChip: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typo.label)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

// MARK: - Area

@MainActor
final class AreaPickerState: ObservableObject {
    /// Width / height constraint, nil = Any.
    @Published var aspectRatio: Double?

    static func clamp(_ rect: CGRect, to size: CGSize) -> CGRect {
        var r = rect.standardized
        r.size.width = min(r.width, size.width)
        r.size.height = min(r.height, size.height)
        r.origin.x = min(max(r.minX, 0), size.width - r.width)
        r.origin.y = min(max(r.minY, 0), size.height - r.height)
        return r.integral
    }
}

private struct AreaPickerOverlay: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var state: AreaPickerState
    var displayID: CGDirectDisplayID

    @State private var dragMode: DragMode?
    @State private var dragOrigin: CGRect = .zero

    private enum DragMode { case create(CGPoint), move, resize(Edge.Set) }

    private var rect: CGRect? {
        if case let .area(id, rect) = coordinator.selection, id == displayID { return rect }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let rect, rect.width > 0, rect.height > 0 {
                    dimmed(around: rect, in: size)
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.white.opacity(0x44 / 255))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                    AreaToolbar(coordinator: coordinator, state: state, displayID: displayID, rect: rect)
                        .fixedSize()
                        .modifier(ToolbarPlacement(selection: rect, screen: size))
                } else {
                    coverColor().allowsHitTesting(false)
                    Text("Drag area you want to record")
                        .font(Theme.Typo.titleMedium)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 2, x: 1, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.crosshair.set() }
            }
        }
    }

    private func dimmed(around rect: CGRect, in size: CGSize) -> some View {
        let cover = coverColor()
        return ZStack(alignment: .topLeading) {
            cover.frame(width: size.width, height: rect.minY)
            cover.frame(width: size.width, height: max(size.height - rect.maxY, 0)).offset(y: rect.maxY)
            cover.frame(width: rect.minX, height: rect.height).offset(y: rect.minY)
            cover.frame(width: max(size.width - rect.maxX, 0), height: rect.height).offset(x: rect.maxX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if dragMode == nil {
                    dragMode = mode(at: value.startLocation)
                    dragOrigin = rect ?? .zero
                }
                guard let dragMode else { return }
                var updated: CGRect
                switch dragMode {
                case .create(let start):
                    updated = CGRect(
                        x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                        width: abs(value.location.x - start.x), height: abs(value.location.y - start.y)
                    )
                    if let ratio = state.aspectRatio { updated.size.height = updated.width / ratio }
                case .move:
                    updated = dragOrigin.offsetBy(dx: value.translation.width, dy: value.translation.height)
                case .resize(let edges):
                    updated = dragOrigin
                    if edges.contains(.leading) { updated.origin.x += value.translation.width; updated.size.width -= value.translation.width }
                    if edges.contains(.trailing) { updated.size.width += value.translation.width }
                    if edges.contains(.top) { updated.origin.y += value.translation.height; updated.size.height -= value.translation.height }
                    if edges.contains(.bottom) { updated.size.height += value.translation.height }
                    if let ratio = state.aspectRatio { updated.size.height = updated.width / ratio }
                }
                coordinator.setArea(displayID: displayID, rect: AreaPickerState.clamp(updated, to: size))
            }
            .onEnded { _ in dragMode = nil }
    }

    private func mode(at point: CGPoint) -> DragMode {
        guard let rect else { return .create(point) }
        let handle: CGFloat = 8
        var edges: Edge.Set = []
        let insideX = point.x > rect.minX - handle && point.x < rect.maxX + handle
        let insideY = point.y > rect.minY - handle && point.y < rect.maxY + handle
        if insideY && abs(point.x - rect.minX) < handle { edges.insert(.leading) }
        if insideY && abs(point.x - rect.maxX) < handle { edges.insert(.trailing) }
        if insideX && abs(point.y - rect.minY) < handle { edges.insert(.top) }
        if insideX && abs(point.y - rect.maxY) < handle { edges.insert(.bottom) }
        if !edges.isEmpty { return .resize(edges) }
        if rect.contains(point) { return .move }
        return .create(point)
    }
}

/// Toolbar 20 px below the selection, else above, else inside the top.
private struct ToolbarPlacement: ViewModifier {
    var selection: CGRect
    var screen: CGSize

    func body(content: Content) -> some View {
        content
            .alignmentGuide(.leading) { d in -(clampedX(width: d.width)) }
            .alignmentGuide(.top) { d in -(y(height: d.height)) }
    }

    private func clampedX(width: CGFloat) -> CGFloat {
        min(max(selection.midX - width / 2, 10), screen.width - width - 10)
    }

    private func y(height: CGFloat) -> CGFloat {
        if selection.maxY + 20 + height < screen.height { return selection.maxY + 20 }
        if selection.minY - 20 - height > 0 { return selection.minY - 20 - height }
        return 20
    }
}

private struct AreaToolbar: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var state: AreaPickerState
    @ObservedObject var preferences = Preferences.shared
    var displayID: CGDirectDisplayID
    var rect: CGRect
    private let aspectAnchor = AnchorHolder()
    private let savedAnchor = AnchorHolder()

    private var isTooSmall: Bool {
        rect.width < RecordingCoordinator.minimumAreaSize || rect.height < RecordingCoordinator.minimumAreaSize
    }

    var body: some View {
        VStack(spacing: Theme.gap(1)) {
            VStack(alignment: .leading, spacing: Theme.gap(2)) {
                fieldsRow("Size", a: value(\.size.width), b: value(\.size.height), separator: "×")
                fieldsRow("Position", a: value(\.origin.x), b: value(\.origin.y), separator: " ")
                HStack(spacing: Theme.gap(1)) {
                    toolbarDropdown(icon: "aspectratio", tooltip: "Set crop aspect ratio", anchor: aspectAnchor, isSet: state.aspectRatio != nil, action: aspectMenu)
                    toolbarDropdown(icon: "rectangle.dashed", title: "Saved", tooltip: "Use and manage saved area dimensions", anchor: savedAnchor, isSet: false, action: savedMenu)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1E1E1E)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)

            if isTooSmall {
                Text("Minimal size is 150×150px.")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Colors.tertiary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.background.opacity(0.8)))
            } else {
                StartRecordingButton(coordinator: coordinator)
            }
        }
        .foregroundStyle(.white)
    }

    private func value(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<String> {
        Binding(
            get: { String(Int(rect[keyPath: keyPath])) },
            set: { text in
                guard let number = Double(text) else { return }
                var updated = rect
                updated[keyPath: keyPath] = CGFloat(number)
                coordinator.setArea(displayID: displayID, rect: AreaPickerState.clamp(updated, to: CGDisplayBounds(displayID).size))
            }
        )
    }

    private func fieldsRow(_ label: String, a: Binding<String>, b: Binding<String>, separator: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.Typo.label).opacity(Theme.tertiaryOpacity).frame(width: 52, alignment: .leading)
            NumberField(text: a)
            Text(separator).font(Theme.Typo.label).opacity(Theme.tertiaryOpacity)
            NumberField(text: b)
            Text("px").font(Theme.Typo.label).opacity(Theme.tertiaryOpacity)
        }
    }

    private func toolbarDropdown(icon: String, title: String? = nil, tooltip: String, anchor: AnchorHolder, isSet: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                if let title { Text(title).font(Theme.Typo.controlCopy) }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSet ? Color.white.opacity(0.1) : Theme.Colors.hover.opacity(0.5)))
            .background(MenuAnchor(holder: anchor))
        }
        .buttonStyle(.plain)
        .tooltip(tooltip)
    }

    private func aspectMenu() {
        let menu = MenuBuilder()
        let options: [(String, Double?)] = [("Any", nil), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("3:4", 3.0 / 4), ("9:16", 9.0 / 16)]
        for (label, ratio) in options {
            menu.item(label, checked: state.aspectRatio == ratio) {
                state.aspectRatio = ratio
                if let ratio {
                    var updated = rect
                    updated.size.width = max(updated.width, 200)
                    updated.size.height = max(updated.width / ratio, 200)
                    updated.size.width = updated.height * ratio
                    coordinator.setArea(displayID: displayID, rect: AreaPickerState.clamp(updated, to: CGDisplayBounds(displayID).size))
                }
            }
        }
        menu.popUp(below: aspectAnchor.view)
    }

    private func savedMenu() {
        let menu = MenuBuilder()
        let current = AreaSize(width: Int(rect.width), height: Int(rect.height))
        if preferences.recordingAreaCropPresets.isEmpty {
            menu.disabled("No saved dimensions")
        } else {
            for size in preferences.recordingAreaCropPresets {
                menu.item("\(size.width) × \(size.height)" + (size == current ? " (current)" : "")) {
                    var updated = rect
                    updated.size = CGSize(width: size.width, height: size.height)
                    coordinator.setArea(displayID: displayID, rect: AreaPickerState.clamp(updated, to: CGDisplayBounds(displayID).size))
                }
            }
        }
        if !preferences.recordingAreaCropPresets.contains(current) && !isTooSmall {
            menu.group("manage")
            menu.item("Save current dimensions") { preferences.recordingAreaCropPresets.append(current) }
        }
        if !preferences.recordingAreaCropPresets.isEmpty {
            menu.group("manage")
            menu.submenu("Delete saved dimensions") { sub in
                for size in preferences.recordingAreaCropPresets {
                    sub.item("Delete \(size.width) × \(size.height)", destructive: true) {
                        preferences.recordingAreaCropPresets.removeAll { $0 == size }
                    }
                }
            }
        }
        menu.popUp(below: savedAnchor.view)
    }
}

/// 44×22 numeric field, radius 6.
private struct NumberField: View {
    @Binding var text: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Typo.label.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 44, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, value in if !focused { draft = value } }
            .onSubmit { text = draft }
            .onChange(of: focused) { _, isFocused in if !isFocused { text = draft } }
    }
}

// MARK: - Device (ExternalDeviceRecordingPicker)

/// Shown on every display after choosing an iPhone/iPad: how to get it ready, its live status,
/// and the Start button once it can be recorded.
private struct DeviceRecordingOverlay: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var devices = ExternalDeviceDiscovery.shared

    private var device: ExternalDevice? { coordinator.selectedDevice }

    /// `{K}`: iPhone, iPad or Device.
    private var kind: String { device?.kind ?? "Device" }

    var body: some View {
        ZStack {
            coverColor()
                .contentShape(Rectangle())
                .onTapGesture { coordinator.escape() }
            VStack(spacing: Theme.gap(3)) {
                VStack(spacing: 22.6) {
                    Text("This is an experimental feature.")
                        .font(Theme.Typo.copy)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
                    HStack(spacing: 8) {
                        if kind == "iPhone" { Image(systemName: "apps.iphone") } else if kind == "iPad" { Image(systemName: "apps.ipad") }
                        Image(systemName: "cable.connector")
                    }
                    .font(Theme.Typo.hero)
                    if let device {
                        Text("Record \(device.menuLabel)").font(Theme.Typo.title).multilineTextAlignment(.center)
                    }
                }
                instructions
                    .font(Theme.Typo.copy)
                    .multilineTextAlignment(.center)
                VStack(spacing: 8) {
                    status
                    Button {
                        NSWorkspace.shared.open(DeviceSourceMenu.guideURL)
                        coordinator.escape()
                    } label: {
                        Text("\(kind) recording guide").font(Theme.Typo.label).underline()
                    }
                    .buttonStyle(GuideLinkStyle())
                }
            }
            .padding(48)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.backgroundAccent))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.175), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            .foregroundStyle(.white)
        }
    }

    private var instructions: Text {
        var start = AttributedString("Start Recording")
        start.foregroundColor = Theme.Colors.primaryActiveText
        start.font = Theme.Typo.copy.weight(.semibold)
        func strong(_ s: String) -> AttributedString {
            var a = AttributedString(s)
            a.font = Theme.Typo.copy.weight(.semibold)
            return a
        }
        var text = AttributedString("Unlock your ")
        text += strong(kind)
        text += AttributedString(" before you click ")
        text += start
        text += AttributedString(" and tap ")
        text += strong("\u{201C}Trust\u{00A0}this\u{00A0}computer\u{201D}")
        text += AttributedString(" if asked on your \(kind). If your \(kind) asks what accessory is connected, tap ")
        text += strong("\u{201C}Other Device\u{201D}")
        text += AttributedString(".")
        return Text(text)
    }

    @ViewBuilder
    private var status: some View {
        switch device?.availability {
        case nil: StatusPill(text: "Device not found - make sure it is still connected")
        case .tapTrustOnDevice: StatusPill(text: "Tap \u{201C}Trust\u{201D} on your device")
        case .reconnectCable: StatusPill(text: "Reconnect your device")
        case .available: StartRecordingButton(coordinator: coordinator)
        }
    }
}

private struct StatusPill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.Typo.copy)
            .foregroundStyle(Color.white.opacity(0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
    }
}

/// Opacity 0.3, 0.6 on hover, 0.8 while pressed.
private struct GuideLinkStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : hovered ? 0.6 : 0.3)
            .onHover { hovered = $0 }
    }
}
