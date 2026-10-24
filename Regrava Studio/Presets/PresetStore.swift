import AppKit
import Combine
import Foundation
import RegravaCore

/// Presets saved as folders (`preset.json` plus the files the settings use) (presets store).
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    struct Entry: Identifiable, Hashable {
        var preset: Preset
        var folder: URL
        var id: UUID { preset.id }
    }

    @Published private(set) var presets: [Entry] = []
    @Published private(set) var hasAccess = true

    static let configFileName = "preset.json"

    /// Where presets live when "Save presets in" is not set.
    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Regrava Studio/Presets", isDirectory: true)
    }

    /// "Save presets in" (`presetsFolderPath`), else the default folder.
    var folder: URL {
        Preferences.shared.presetsFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
    }

    private var folderObserver: AnyCancellable?

    private init() {
        reload()
        folderObserver = Preferences.shared.$presetsFolderPath.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            presets = folders.compactMap { url in
                guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.configFileName)),
                      let preset = try? JSONDecoder().decode(Preset.self, from: data) else { return nil }
                return Entry(preset: preset, folder: url)
            }
            .sorted { $0.preset.name.localizedStandardCompare($1.preset.name) == .orderedAscending }
            hasAccess = true
        } catch {
            hasAccess = false
            presets = []
        }
    }

    func isDefault(_ entry: Entry) -> Bool { Preferences.shared.defaultPresetID == entry.id.uuidString }

    func toggleDefault(_ entry: Entry) {
        Preferences.shared.defaultPresetID = isDefault(entry) ? nil : entry.id.uuidString
        objectWillChange.send()
    }

    var defaultPreset: Entry? { presets.first(where: isDefault) }

    /// "Create new preset": the project's settings and their files.
    func create(name: String, project: Project, bundle: URL) {
        let preset = Preset(name: name, config: project.presetConfig)
        let target = folder.appendingPathComponent(preset.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        write(preset, to: target, copyingFrom: bundle)
        reload()
    }

    /// "Update to match currently edited project".
    func sync(_ entry: Entry, with project: Project, bundle: URL) {
        var preset = entry.preset
        preset.config = project.presetConfig
        write(preset, to: entry.folder, copyingFrom: bundle)
        reload()
    }

    func rename(_ entry: Entry, to name: String) {
        var preset = entry.preset
        preset.name = name
        save(preset, in: entry.folder)
        reload()
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.folder)
        if isDefault(entry) { Preferences.shared.defaultPresetID = nil }
        reload()
    }

    func reveal(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
    }

    /// Copies the preset's files into a project so its settings resolve there.
    func copyAssets(of entry: Entry, into bundle: URL) {
        for name in entry.preset.config.assetFileNames {
            let source = entry.folder.appendingPathComponent(name)
            let target = Self.projectLocation(of: name, config: entry.preset.config, bundle: bundle)
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: target)
        }
    }

    /// Background images live in the project folder, background audio in its assets folder.
    static func projectLocation(of name: String, config: PresetConfig, bundle: URL) -> URL {
        name == config.audio.backgroundAudioFileName
            ? ProjectStore.assetsURL(bundle: bundle).appendingPathComponent(name)
            : bundle.appendingPathComponent(name)
    }

    private func write(_ preset: Preset, to folder: URL, copyingFrom bundle: URL) {
        for name in preset.config.assetFileNames {
            let source = Self.projectLocation(of: name, config: preset.config, bundle: bundle)
            let target = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
        save(preset, in: folder)
    }

    private func save(_ preset: Preset, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(preset) {
            try? data.write(to: folder.appendingPathComponent(Self.configFileName), options: .atomic)
        }
    }
}
