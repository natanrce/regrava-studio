import AppKit
import Combine
import Foundation
import RegravaCore

/// Presets saved: a `<name>.regravapreset` package holding `meta.json` (the settings in the
/// project schema, `PresetFile`) and an `assets/` folder with the files they use, in "Save presets
/// in" (default `~/Documents/Regrava Studio Presets`).
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    struct Entry: Identifiable, Hashable {
        var preset: Preset
        var folder: URL
        var id: UUID { preset.id }
        var assetsFolder: URL { folder.appendingPathComponent(PresetFile.assetsFolderName, isDirectory: true) }
    }

    @Published private(set) var presets: [Entry] = []
    @Published private(set) var hasAccess = true

    static let packageExtension = "regravapreset"
    /// Imported preset packages, read the same way.
    static let originalPackageExtension = "screenstudiopreset"

    /// Where presets live when "Save presets in" is not set.
    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Regrava Studio Presets", isDirectory: true)
    }

    /// "Save presets in" (`presetsFolderPath`), else the default folder.
    var folder: URL {
        Preferences.shared.presetsFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
    }

    private var folderObserver: AnyCancellable?

    private init() {
        migrateLegacyPresets()
        reload()
        folderObserver = Preferences.shared.$presetsFolderPath.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    /// The package's id: stable for its name.
    static func id(forPackageNamed name: String) -> UUID {
        var hash = [UInt8](repeating: 0, count: 16)
        for (i, byte) in name.utf8.enumerated() { hash[i % 16] = hash[i % 16] &* 31 &+ byte }
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    static func read(package url: URL) throws -> Preset {
        let config = try PresetFile.decode(Data(contentsOf: url.appendingPathComponent(PresetFile.fileName)))
        return Preset(id: id(forPackageNamed: url.lastPathComponent), name: url.deletingPathExtension().lastPathComponent, config: config)
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            presets = folders.filter { $0.pathExtension == Self.packageExtension }.compactMap { url in
                (try? Self.read(package: url)).map { Entry(preset: $0, folder: url) }
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

    /// A free package name in the presets folder.
    private func packageURL(named name: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(Self.packageExtension)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(Self.packageExtension)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// "Create new preset": the project's settings and their files.
    func create(name: String, project: Project, bundle: URL) {
        let target = packageURL(named: name)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        write(project.presetConfig, to: target, copyingFrom: bundle)
        reload()
    }

    /// "Update to match currently edited project".
    func sync(_ entry: Entry, with project: Project, bundle: URL) {
        write(project.presetConfig, to: entry.folder, copyingFrom: bundle)
        reload()
    }

    func rename(_ entry: Entry, to name: String) {
        let wasDefault = isDefault(entry)
        let target = packageURL(named: name)
        guard (try? FileManager.default.moveItem(at: entry.folder, to: target)) != nil else { return }
        if wasDefault { Preferences.shared.defaultPresetID = Self.id(forPackageNamed: target.lastPathComponent).uuidString }
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

    /// "Import preset...": a preset package copied into the presets folder.
    func importPreset() {
        let panel = NSOpenPanel()
        panel.message = "Import preset"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPreset(at: url)
    }

    func importPreset(at url: URL) {
        guard [Self.packageExtension, Self.originalPackageExtension].contains(url.pathExtension) else {
            Dialogs.info(title: "Invalid file selected", message: "The selected file is not a valid Regrava Studio preset file. Please select a file with the .\(Self.packageExtension) extension.")
            return
        }
        do {
            _ = try Self.read(package: url)
            let target = packageURL(named: url.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            reload()
            AppController.shared.focusedEditor?.model.showToast("Preset imported")
        } catch {
            Dialogs.error(error.localizedDescription)
        }
    }

    /// Copies the preset's files into a project so its settings resolve there.
    func copyAssets(of entry: Entry, into bundle: URL) {
        for name in entry.preset.config.assetFileNames {
            let source = entry.assetsFolder.appendingPathComponent(name)
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

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func write(_ config: PresetConfig, to package: URL, copyingFrom bundle: URL) {
        let assets = package.appendingPathComponent(PresetFile.assetsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for name in config.assetFileNames {
            let source = Self.projectLocation(of: name, config: config, bundle: bundle)
            let target = assets.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
        if let data = try? PresetFile.encode(config, appVersion: Self.appVersion) {
            try? data.write(to: package.appendingPathComponent(PresetFile.fileName), options: .atomic)
        }
    }

    /// Presets saved before the package format (`<uuid>/preset.json` in Application Support)
    /// become packages, keeping the default preset ("Upgrading legacy presets").
    private func migrateLegacyPresets() {
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Regrava Studio/Presets", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in folders {
            guard let data = try? Data(contentsOf: old.appendingPathComponent("preset.json")),
                  let preset = try? JSONDecoder().decode(Preset.self, from: data) else { continue }
            let target = packageURL(named: preset.name)
            let assets = target.appendingPathComponent(PresetFile.assetsFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            for name in preset.config.assetFileNames {
                try? FileManager.default.copyItem(at: old.appendingPathComponent(name), to: assets.appendingPathComponent(name))
            }
            guard let meta = try? PresetFile.encode(preset.config, appVersion: Self.appVersion),
                  (try? meta.write(to: target.appendingPathComponent(PresetFile.fileName))) != nil else { continue }
            if Preferences.shared.defaultPresetID == preset.id.uuidString {
                Preferences.shared.defaultPresetID = Self.id(forPackageNamed: target.lastPathComponent).uuidString
            }
            try? FileManager.default.removeItem(at: old)
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true { try? FileManager.default.removeItem(at: legacy) }
    }
}
