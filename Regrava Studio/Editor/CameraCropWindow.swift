@preconcurrency import AVFoundation
import AppKit
import Combine
import RegravaCore
import SwiftUI

// "Crop Camera" window.

/// Child window "camera-crop-window" (shell).
enum CameraCropWindow {
    /// Pauses playback and opens the window, or focuses it when already open.
    @MainActor
    static func show(for editor: EditorModel) {
        editor.pause()
        let key = "camera-crop-window-\(ObjectIdentifier(editor).hashValue)"
        if ToolWindowController.focus(key) { return }
        let model = CameraCropModel(editor: editor)
        ToolWindowController.open(key: key, title: "Crop Camera", autosaveName: "camera-crop-window") { close in
            AnyView(CameraCropView(model: model, close: close))
        }
    }
}

@MainActor
final class CameraCropModel: ObservableObject {
    let editor: EditorModel
    let mirror: Bool
    @Published var state: CameraCropState
    @Published var frameImage: NSImage?

    init(editor: EditorModel) {
        self.editor = editor
        let project = editor.project
        mirror = project.camera.mirror
        state = CameraCropState(videoSize: project.recording.cameraSize, crop01: project.camera.crop01, mirror: project.camera.mirror)
        loadFrame()
    }

    /// The webcam frame at the playhead, shifted by the camera delay.
    private func loadFrame() {
        guard let name = editor.project.recording.cameraFileName else { return }
        let url = editor.videoURL.deletingLastPathComponent().appendingPathComponent(name)
        let seconds = max(editor.currentSourceTimeMs + editor.project.camera.delayAdjustmentMs, 0) / 1000
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                frameImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    /// "Confirm changes": stored unmirrored, nil for the whole frame.
    func confirm() {
        let crop = state.confirmedCrop01(mirror: mirror)
        editor.change { $0.camera.crop01 = crop }
    }

    /// Arrow keys: move by 1 (⇧ 10) px; with ⌘, ←/→ change the width and ↑/↓ the height
    /// (↑ reduces it, as the code does).
    func nudge(_ direction: MoveCommandDirection, shift: Bool, command: Bool) {
        let step = shift ? 10.0 : 1
        var c = state.crop
        switch (direction, command) {
        case (.left, false): c.x -= step
        case (.right, false): c.x += step
        case (.up, false): c.y -= step
        case (.down, false): c.y += step
        case (.left, true): c.width -= step
        case (.right, true): c.width += step
        case (.up, true): c.height -= step
        case (.down, true): c.height += step
        default: return
        }
        state.setCrop(c)
    }
}

struct CameraCropView: View {
    @ObservedObject var model: CameraCropModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: Theme.gap(1)) {
            HStack(spacing: 0) {
                Text("Crop Camera")
                    .font(Theme.Typo.copy.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: 300)
                    .frame(maxWidth: .infinity)
                CropToolbar(model: model).fixedSize()
            }
            .padding(.leading, 90)
            .padding(.trailing, 12)
            .frame(height: 60)
            VStack(spacing: Theme.gap(1)) {
                CropEditor(model: model)
                HStack(spacing: Theme.gap(1)) {
                    RSButton(title: "Confirm changes", kind: .primary, shortcut: "↩") {
                        model.confirm()
                        close()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.state.isTooSmall)
                    RSButton(title: "Discard changes", kind: .secondary, action: close)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.state.expandToFullSize() }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            let directions: [KeyEquivalent: MoveCommandDirection] = [.leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down]
            guard let direction = directions[press.key] else { return .ignored }
            model.nudge(direction, shift: press.modifiers.contains(.shift), command: press.modifiers.contains(.command))
            return .handled
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Editor

/// The frame fitted to its aspect with the selection on top: outside dimmed at 40%, radius 10,
/// dashed grid at 25/50/75%, four corner handles, edge bars when no aspect is locked.
private struct CropEditor: View {
    @ObservedObject var model: CameraCropModel
    @State private var dragStart: (crop: Rect2, kind: DragKind)?

    private enum DragKind { case move, newSelection(Vec2), corner(Int), edge(Int) }

    var body: some View {
        GeometryReader { proxy in
            let frame = model.state.frame
            let fitted = fit(frame.width / frame.height, in: proxy.size)
            ZStack(alignment: .topLeading) {
                content(size: fitted)
            }
            .frame(width: fitted.width, height: fitted.height)
            .padding(5)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .bottom) {
                if model.state.isTooSmall {
                    Text("Minimal size is 200x200")
                        .font(Theme.Typo.label.weight(.medium))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Capsule().fill(Theme.Colors.background.opacity(0.75)))
                        .padding(.bottom, 24)
                }
            }
        }
        .padding(4)
    }

    private func fit(_ aspect: Double, in size: CGSize) -> CGSize {
        let available = CGSize(width: max(size.width - 10, 1), height: max(size.height - 10, 1))
        return available.width / available.height > aspect
            ? CGSize(width: available.height * aspect, height: available.height)
            : CGSize(width: available.width, height: available.width / aspect)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let scale = size.width / model.state.frame.width
        let crop = model.state.crop
        let selection = CGRect(x: crop.x * scale, y: crop.y * scale, width: crop.width * scale, height: crop.height * scale)
        Group {
            if let image = model.frameImage {
                Image(nsImage: image).resizable().scaleEffect(x: model.mirror ? -1 : 1, y: 1)
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Dimmed outside the selection.
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRoundedRect(in: selection, cornerSize: CGSize(width: 10, height: 10))
        }
        .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        grid(selection)
        // Whole-surface gesture: inside moves, outside draws a new selection.
        Color.white.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .gesture(drag(scale: scale, selection: selection))
        handles(selection, scale: scale)
    }

    private func grid(_ r: CGRect) -> some View {
        Canvas { context, _ in
            for (f, opacity) in [(0.25, 0.2), (0.5, 0.5), (0.75, 0.2)] {
                var v = Path(), h = Path()
                v.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); v.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
                h.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); h.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
                let style = StrokeStyle(lineWidth: 1, dash: [4, 4])
                context.stroke(v, with: .color(Color(hex: 0x888888).opacity(opacity)), style: style)
                context.stroke(h, with: .color(Color(hex: 0x888888).opacity(opacity)), style: style)
            }
        }
        .allowsHitTesting(false)
    }

    private func drag(scale: CGFloat, selection: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = Vec2(value.startLocation.x / scale, value.startLocation.y / scale)
                let point = Vec2(value.location.x / scale, value.location.y / scale)
                if dragStart == nil {
                    dragStart = (model.state.crop, selection.contains(value.startLocation) ? .move : .newSelection(start))
                }
                guard let dragStart else { return }
                var c = dragStart.crop
                switch dragStart.kind {
                case .move:
                    c.x += point.x - start.x
                    c.y += point.y - start.y
                case .newSelection(let origin):
                    c = Rect2(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y))
                default: return
                }
                model.state.setCrop(c)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Corner handles: 24 px hit area, a 10 px #111 dot with a white border.
    @ViewBuilder
    private func handles(_ r: CGRect, scale: CGFloat) -> some View {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        ForEach(0..<4, id: \.self) { index in
            Circle()
                .fill(Color(hex: 0x111111))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                .frame(width: 10, height: 10)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .position(corners[index])
                .gesture(resize(.corner(index), scale: scale))
        }
        if model.state.forcedAspectRatio == nil {
            // Invisible 6 px edge bars: top, right, bottom, left.
            let bars = [
                CGRect(x: r.minX + 12, y: r.minY - 3, width: max(r.width - 24, 0), height: 6),
                CGRect(x: r.maxX - 3, y: r.minY + 12, width: 6, height: max(r.height - 24, 0)),
                CGRect(x: r.minX + 12, y: r.maxY - 3, width: max(r.width - 24, 0), height: 6),
                CGRect(x: r.minX - 3, y: r.minY + 12, width: 6, height: max(r.height - 24, 0)),
            ]
            ForEach(0..<4, id: \.self) { index in
                Color.white.opacity(0.001)
                    .frame(width: bars[index].width, height: bars[index].height)
                    .position(x: bars[index].midX, y: bars[index].midY)
                    .gesture(resize(.edge(index), scale: scale))
            }
        }
    }

    private func resize(_ kind: DragKind, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = (model.state.crop, kind) }
                guard let dragStart else { return }
                let o = dragStart.crop
                let dx = value.translation.width / scale, dy = value.translation.height / scale
                var x0 = o.x, y0 = o.y, x1 = o.endX, y1 = o.endY
                switch dragStart.kind {
                case .corner(let i):
                    if i == 0 || i == 3 { x0 += dx } else { x1 += dx }
                    if i == 0 || i == 1 { y0 += dy } else { y1 += dy }
                    if let ratio = model.state.forcedAspectRatio.map({ $0.x / $0.y }) {
                        // Keeps the locked aspect from the dragged width, anchored on the opposite corner.
                        let h = abs(x1 - x0) / ratio
                        if i == 0 || i == 1 { y0 = y1 - h } else { y1 = y0 + h }
                    }
                case .edge(let i):
                    switch i {
                    case 0: y0 += dy
                    case 1: x1 += dx
                    case 2: y1 += dy
                    default: x0 += dx
                    }
                default: return
                }
                model.state.setCrop(Rect2(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)))
            }
            .onEnded { _ in dragStart = nil }
    }
}

// MARK: - Toolbar

private struct CropToolbar: View {
    @ObservedObject var model: CameraCropModel
    @State private var isAspectOpen = false
    @State private var isShortcutsOpen = false

    var body: some View {
        let crop = model.state.crop
        HStack(spacing: Theme.gap(2.5)) {
            HStack(spacing: Theme.gap(1)) {
                Text("Size").font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary).fixedSize().tooltip("Minimum value 200x200")
                CropNumberField(value: crop.width) { v in var c = model.state.crop; c.width = v; model.state.setCrop(c, applyConstraints: false) }
                Text("×").foregroundStyle(Theme.Colors.tertiary).fixedSize()
                CropNumberField(value: crop.height) { v in var c = model.state.crop; c.height = v; model.state.setCrop(c, applyConstraints: false) }
                aspectButton
            }
            HStack(spacing: Theme.gap(1)) {
                Text("Position").font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary).fixedSize()
                CropNumberField(value: crop.x) { v in var c = model.state.crop; c.x = v; model.state.setCrop(c) }
                CropNumberField(value: crop.y) { v in var c = model.state.crop; c.y = v; model.state.setCrop(c) }
            }
            RSButton(title: "Reset", icon: "crop", kind: .secondary, size: .small) { model.state.expandToFullSize() }.fixedSize()
            RSIconButton(icon: "keyboard", tooltip: "Show keyboard shortcuts") { isShortcutsOpen = true }
                .popover(isPresented: $isShortcutsOpen) { shortcuts }
        }
    }

    private var aspectLabel: String {
        model.state.forcedAspectRatio.map { "\(Int($0.x)):\(Int($0.y))" } ?? "Any"
    }

    /// Any, 16:9, 4:3, 1:1, 3:4, 9:16 and a custom x:y.
    private var aspectButton: some View {
        RSButton(title: aspectLabel, icon: "aspectratio", kind: model.state.forcedAspectRatio == nil ? .secondaryInline : .subtle, size: .small) { isAspectOpen = true }
            .fixedSize()
            .tooltip("Set crop aspect ratio")
            .popover(isPresented: $isAspectOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    aspectRow("Any", nil)
                    ForEach(CameraCropState.aspectRatioOptions.indices, id: \.self) { i in
                        let o = CameraCropState.aspectRatioOptions[i]
                        aspectRow("\(Int(o.x)):\(Int(o.y))", Vec2(o.x, o.y))
                    }
                    Divider().padding(.vertical, 4)
                    Text("Custom aspect ratio").font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary)
                    HStack(spacing: Theme.gap(1)) {
                        CropNumberField(value: model.state.forcedAspectRatio?.x ?? 1) { v in
                            model.state.setForcedAspectRatio(Vec2(max(v, 1), model.state.forcedAspectRatio?.y ?? 1))
                        }
                        Text(":").foregroundStyle(Theme.Colors.tertiary)
                        CropNumberField(value: model.state.forcedAspectRatio?.y ?? 1) { v in
                            model.state.setForcedAspectRatio(Vec2(model.state.forcedAspectRatio?.x ?? 1, max(v, 1)))
                        }
                    }
                }
                .padding(Theme.gap(1.5))
                .environment(\.colorScheme, .dark)
            }
    }

    private func aspectRow(_ title: String, _ ratio: Vec2?) -> some View {
        Button { model.state.setForcedAspectRatio(ratio) } label: {
            HStack {
                Text(title)
                Spacer()
                if model.state.forcedAspectRatio == ratio { Image(systemName: "checkmark") }
            }
            .font(Theme.Typo.controlCopy)
            .padding(.horizontal, 8)
            .frame(width: 160, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shortcuts: some View {
        let rows: [(String, String)] = [
            ("←", "Move left by 1px"), ("→", "Move right by 1px"), ("↑", "Move up by 1px"), ("↓", "Move down by 1px"),
            ("⇧ ←", "Move left by 10px"), ("⇧ →", "Move right by 10px"), ("⇧ ↑", "Move up by 10px"), ("⇧ ↓", "Move down by 10px"),
            ("⌘ ←", "Reduce width by 1px"), ("⌘ →", "Increase width by 1px"), ("⌘ ↑", "Increase height by 1px"), ("⌘ ↓", "Reduce height by 1px"),
            ("⌘ ⇧ ←", "Reduce width by 10px"), ("⌘ ⇧ →", "Increase width by 10px"), ("⌘ ⇧ ↑", "Increase height by 10px"), ("⌘ ⇧ ↓", "Reduce height by 10px"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    Text(rows[i].1).font(Theme.Typo.label)
                    Spacer(minLength: 24)
                    Text(rows[i].0).font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary)
                }
            }
        }
        .padding(Theme.gap(2))
        .frame(width: 260)
        .environment(\.colorScheme, .dark)
    }
}

/// Integer input, 7.5ch wide, centred.
private struct CropNumberField: View {
    var value: Double
    var commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Theme.Typo.controlCopy.monospacedDigit())
            .frame(width: 52, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
            .focused($focused)
            .onAppear { text = "\(Int(value.rounded()))" }
            .onChange(of: value) { _, v in if !focused { text = "\(Int(v.rounded()))" } }
            .onSubmit { if let v = Double(text) { commit(v) }; text = "\(Int(value.rounded()))" }
            .onExitCommand { focused = false }
    }
}
