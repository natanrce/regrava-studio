@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import RegravaCore
import RegravaRender
import SwiftUI

// "Color preset studio" window.

enum ColorPresetStudio {
    @MainActor
    static func show(for editor: EditorModel, onCreated: @escaping () -> Void) {
        let key = "lut-studio-window-\(ObjectIdentifier(editor).hashValue)"
        if ToolWindowController.focus(key) { return }
        let model = ColorPresetStudioModel(editor: editor)
        ToolWindowController.open(key: key, title: "Color preset studio", autosaveName: "lut-studio-window") { close in
            AnyView(ColorPresetStudioView(model: model, close: close, onCreated: onCreated))
        }
    }
}

@MainActor
final class ColorPresetStudioModel: ObservableObject {
    let editor: EditorModel
    @Published var intent = ColorPresetIntent() {
        didSet {
            let changed = oldValue.warmth != intent.warmth || oldValue.contrast != intent.contrast
                || oldValue.colorIntensity != intent.colorIntensity || oldValue.backgroundPop != intent.backgroundPop
            if changed { regenerate() }
        }
    }
    @Published var preview: NSImage?
    @Published var isCreating = false
    private var base: CIImage?
    private var task: Task<Void, Never>?
    private static let context = CIContext()

    init(editor: EditorModel) {
        self.editor = editor
        Task {
            base = await Self.baseImage(editor: editor)
            regenerate()
        }
    }

    /// The webcam's first frame, or the hue swatch without a webcam ("the preset studio
    /// previews the color swatch").
    private static func baseImage(editor: EditorModel) async -> CIImage {
        if let name = editor.project.recording.cameraFileName {
            let url = editor.videoURL.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1280, height: 1280)
                if let frame = try? await generator.image(at: .zero).image { return CIImage(cgImage: frame) }
            }
        }
        let size = 256
        return CIImage(bitmapData: Data(ColorGrading.swatchPixels(size: size)), bytesPerRow: size * 4, size: CGSize(width: size, height: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(size)))
    }

    /// Live preview: the LUT is generated again whenever a slider moves.
    private func regenerate() {
        guard let base else { return }
        task?.cancel()
        let look = intent.look
        task = Task.detached(priority: .userInitiated) {
            let lut = ColorGrading.lut(for: look)
            guard !Task.isCancelled else { return }
            let graded = ColorGradeFilter.apply(lut, to: base)
            guard let cg = Self.context.createCGImage(graded, from: base.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
            await MainActor.run { self.preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }

    /// "Create preset": saved to the library, copied into the project and selected.
    func create() -> Bool {
        isCreating = true
        let look = intent.look
        guard let entry = try? LUTLibrary.write(name: look.name, contents: intent.cube) else {
            isCreating = false
            return false
        }
        editor.selectLibraryLUT(entry)
        return true
    }
}

/// Preview (contain, radius 8) beside a 260 px column of fields, padding 0 20 20.
struct ColorPresetStudioView: View {
    @ObservedObject var model: ColorPresetStudioModel
    var close: () -> Void
    var onCreated: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Color preset studio")
                .font(Theme.Typo.copy.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.leading, 90)
                .padding(.trailing, 12)
                .frame(height: 60)
            HStack(alignment: .top, spacing: Theme.gap(3)) {
                Group {
                    if let preview = model.preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: Theme.gap(3)) {
                    VStack(alignment: .leading, spacing: Theme.gap(3)) {
                        NamedField(name: "Preset name") {
                            RSTextField(placeholder: "My preset", text: $model.intent.name)
                        }
                        slider("Warmth", \.warmth, -1...1, reset: 0)
                        slider("Background pop", \.backgroundPop, 0...1, reset: ColorPresetIntent().backgroundPop)
                        slider("Contrast", \.contrast, -1...1, reset: ColorPresetIntent().contrast)
                        slider("Color intensity", \.colorIntensity, -1...1, reset: ColorPresetIntent().colorIntensity)
                    }
                    Spacer()
                    VStack(spacing: Theme.gap(1)) {
                        RSButton(title: "Create preset", kind: .primary, isWide: true, shortcut: "↩") {
                            if model.create() {
                                onCreated()
                                close()
                            }
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(model.isCreating)
                        RSButton(title: "Cancel", kind: .secondary, isWide: true, action: close)
                    }
                }
                .frame(width: 260)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .environment(\.colorScheme, .dark)
    }

    private func slider(_ name: String, _ keyPath: WritableKeyPath<ColorPresetIntent, Double>, _ range: ClosedRange<Double>, reset: Double) -> some View {
        SliderField(name: name, value: Binding(get: { model.intent[keyPath: keyPath] }, set: { model.intent[keyPath: keyPath] = $0 }), range: range, step: 0.01, resetValue: reset)
    }
}
