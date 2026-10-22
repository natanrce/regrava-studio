@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import RegravaCore
import RegravaRender
import SwiftUI

// "Color grading" picker of the Camera Style panel.

/// The user's LUT library (a folder the app watches).
enum LUTLibrary {
    struct Entry: Identifiable, Hashable {
        var url: URL
        var id: String { url.path }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Regrava Studio/Regrava Studio LUTs", isDirectory: true)
    }

    static func entries() -> [Entry] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Entry(url: $0) }
    }

    /// `luts.addToLibrary` / `luts.writeToLibrary`: a free file name in the library.
    static func write(name: String, contents: String) throws -> Entry {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(name).cube")
        var index = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(index).cube")
            index += 1
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return Entry(url: url)
    }

    /// "Move to Trash" (`luts.removeFromLibrary`).
    static func moveToTrash(_ entry: Entry) {
        if (try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}

extension EditorModel {
    /// `project.writeFileToProject`: stored as `<name>-<10 alphanumerics>.cube` in the assets.
    func writeProjectLUT(name: String, contents: String) -> String? {
        let assets = ProjectStore.assetsURL(bundle: bundleURL)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let suffix = String((0..<10).map { _ in characters.randomElement()! })
        let fileName = "\(name)-\(suffix).cube"
        do {
            try contents.write(to: assets.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            return fileName
        } catch {
            return nil
        }
    }

    /// `setCameraLut`: selecting another grade or "Original" deletes the previous `.cube` asset
    /// from the project.
    func setCameraLUT(_ asset: String?) {
        let old = project.camera.lut
        change { $0.camera.lut = asset }
        if let old, old != asset {
            try? FileManager.default.removeItem(at: ProjectStore.assetsURL(bundle: bundleURL).appendingPathComponent(old))
        }
    }

    func selectLook(_ look: ColorLook) {
        let contents = ColorGrading.builtInCube(for: look)
        guard let asset = writeProjectLUT(name: look.name, contents: contents) else { return }
        setCameraLUT(asset)
    }

    func selectLibraryLUT(_ entry: LUTLibrary.Entry) {
        guard let contents = try? String(contentsOf: entry.url, encoding: .utf8),
              let asset = writeProjectLUT(name: entry.name, contents: contents) else { return }
        setCameraLUT(asset)
    }

    /// "Load your LUT file...": pick a `.cube`, add it to the library and use it.
    func loadLUTFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube")].compactMap { $0 }
        panel.message = "Choose a 3D LUT (.cube) file"
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        do {
            _ = try ColorLUT(cube: contents)
            let entry = try LUTLibrary.write(name: url.deletingPathExtension().lastPathComponent, contents: contents)
            selectLibraryLUT(entry)
        } catch ColorLUT.ParseError.oneDimensional {
            errorMessage = "1D LUTs are not supported - use a 3D .cube file"
        } catch {
            errorMessage = "Could not load the LUT file."
        }
    }

    var cameraLUTDisplayName: String? { project.camera.lut.map(ColorGrading.displayName(ofAsset:)) }
}

/// Look LUTs are generated once per launch (`Se = memoize(xe)`).
actor LookLUTCache {
    static let shared = LookLUTCache()
    private var luts: [String: ColorLUT] = [:]

    func lut(for look: ColorLook) -> ColorLUT {
        if let lut = luts[look.name] { return lut }
        let lut = ColorGrading.lut(for: look)
        luts[look.name] = lut
        return lut
    }
}

@MainActor
final class ColorGradingPickerModel: ObservableObject {
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var library: [LUTLibrary.Entry] = []
    private var base: CIImage?
    private static let context = CIContext()

    func load(cameraURL: URL?) {
        library = LUTLibrary.entries()
        Task {
            let base = await Self.baseImage(cameraURL: cameraURL)
            self.base = base
            thumbnails["Original"] = Self.render(base)
            for look in ColorGrading.builtInLooks {
                let lut = await LookLUTCache.shared.lut(for: look)
                thumbnails["look:\(look.name)"] = Self.render(ColorGradeFilter.apply(lut, to: base))
            }
            refreshLibraryThumbnails()
        }
    }

    func reloadLibrary() {
        library = LUTLibrary.entries()
        refreshLibraryThumbnails()
    }

    private func refreshLibraryThumbnails() {
        guard let base else { return }
        for entry in library where thumbnails["user:\(entry.id)"] == nil {
            guard let text = try? String(contentsOf: entry.url, encoding: .utf8), let lut = try? ColorLUT(cube: text) else { continue }
            thumbnails["user:\(entry.id)"] = Self.render(ColorGradeFilter.apply(lut, to: base))
        }
    }

    /// The webcam at t = 0 filling the tile, or the hue/lightness swatch without a webcam.
    private static func baseImage(cameraURL: URL?) async -> CIImage {
        let side: CGFloat = 72
        if let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: cameraURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            if let frame = try? await generator.image(at: .zero).image {
                let image = CIImage(cgImage: frame)
                let k = max(side / image.extent.width, side / image.extent.height)
                let scaled = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
                return scaled.transformed(by: CGAffineTransform(translationX: -(scaled.extent.width - side) / 2, y: -(scaled.extent.height - side) / 2))
                    .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
        let size = 256
        let pixels = ColorGrading.swatchPixels(size: size)
        let swatch = CIImage(bitmapData: Data(pixels), bytesPerRow: size * 4, size: CGSize(width: size, height: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(size)))
        return swatch.transformed(by: CGAffineTransform(scaleX: side / CGFloat(size), y: side / CGFloat(size)))
    }

    private static func render(_ image: CIImage) -> NSImage? {
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 72, height: 72), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 36, height: 36))
    }
}

/// Original, the 12 looks, the user's LUTs and the plus tile, wrapping.
struct ColorGradingPicker: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var model = ColorGradingPickerModel()

    private var selectedName: String? { editor.cameraLUTDisplayName }

    var body: some View {
        WrappingHStack(spacing: Theme.gap(1)) {
            GradeTile(image: model.thumbnails["Original"], tooltip: "Original", isSelected: editor.project.camera.lut == nil) {
                editor.setCameraLUT(nil)
            }
            ForEach(ColorGrading.builtInLooks, id: \.name) { look in
                GradeTile(image: model.thumbnails["look:\(look.name)"], tooltip: look.name, isSelected: selectedName == look.name) {
                    editor.selectLook(look)
                }
            }
            ForEach(model.library) { entry in
                GradeTile(image: model.thumbnails["user:\(entry.id)"], tooltip: entry.name, isSelected: selectedName == entry.name, onDelete: { remove(entry) }) {
                    editor.selectLibraryLUT(entry)
                }
            }
            PlusTile(editor: editor, onLibraryChange: { model.reloadLibrary() })
        }
        .onAppear {
            let cameraURL = editor.project.recording.cameraFileName.map { editor.videoURL.deletingLastPathComponent().appendingPathComponent($0) }
            model.load(cameraURL: cameraURL)
        }
    }

    /// Removing the selected LUT's library entry also clears the grade.
    private func remove(_ entry: LUTLibrary.Entry) {
        if entry.name == selectedName { editor.setCameraLUT(nil) }
        LUTLibrary.moveToTrash(entry)
        model.reloadLibrary()
    }
}

/// 36×36, radius 6, an overlay border at #fff8, a 1 px outline 1 px away (text at 0.4 on hover,
/// 0.8 when selected).
private struct GradeTile: View {
    var image: NSImage?
    var tooltip: String
    var isSelected: Bool
    var onDelete: (() -> Void)?
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image { Image(nsImage: image).resizable() } else { Theme.Colors.lighterBg }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0x88 / 255.0), lineWidth: 1).blendMode(.overlay))
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Colors.text.opacity(isSelected ? 0.8 : hovered ? 0.4 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isSelected || onDelete != nil)
        .overlay(alignment: .topLeading) {
            // Delete badge: 14×14, text colour, `minus` at 0.7, shown on hover.
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.background)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Theme.Colors.text))
                }
                .buttonStyle(.plain)
                .tooltip("Move to Trash")
                .offset(x: -3, y: -3)
                .opacity(hovered ? 1 : 0)
            }
        }
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) { Label("Move to Trash", systemImage: "trash") }
            }
        }
        .onHover { hovered = $0 }
        .tooltip(tooltip)
    }
}

private struct PlusTile: View {
    @ObservedObject var editor: EditorModel
    var onLibraryChange: () -> Void
    @State private var hovered = false

    var body: some View {
        Menu {
            Button {
                ColorPresetStudio.show(for: editor, onCreated: onLibraryChange)
            } label: { Label("Create your color preset...", systemImage: "paintpalette") }
            Button {
                editor.loadLUTFile()
                onLibraryChange()
            } label: { Label("Load your LUT file...", systemImage: "folder") }
        } label: {
            Image(systemName: "plus")
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Colors.text.opacity(hovered ? 0.4 : 0), lineWidth: 1))
        .onHover { hovered = $0 }
        .tooltip("Create a color preset or load a LUT file...")
    }
}

/// Rows that wrap, like CSS `flex-wrap`.
struct WrappingHStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
