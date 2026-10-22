import AVFoundation
import AppKit
import Combine
import RegravaCore
import UniformTypeIdentifiers

/// Background audio categories.
enum BackgroundAudioCategory: String, CaseIterable, Hashable {
    case loFi = "lo-fi"
    case commercial
    case electronic
    case instrumental
    case userLibrary = "user library"

    /// Title-cased.
    var title: String {
        switch self {
        case .loFi: return "Lo-Fi"
        case .userLibrary: return "User Library"
        default: return rawValue.capitalized
        }
    }
}

/// The user's folder of background audio tracks.
enum BackgroundAudioLibrary {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Regrava Studio/Background Audio", isDirectory: true)
    }

    static func tracks() -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["mp3", "m4a"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func reveal() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Name without extension, truncated to `maxLength` characters when given.
    /// `displayFromTrackName`: title case, truncated to `prefix(max − 3) + "..."`.
    static func displayName(_ fileName: String, maxLength: Int? = nil) -> String {
        let name = titleCase((fileName as NSString).deletingPathExtension)
        guard let maxLength, name.count > maxLength else { return name }
        return String(name.prefix(maxLength - 3)) + "..."
    }

    /// Upper-cases the first letter of each space- and hyphen-separated piece.
    static func titleCase(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// Copies into the project's assets folder; returns the stored file name.
    static func copy(_ source: URL, intoProject bundle: URL) -> String? {
        let assets = ProjectStore.assetsURL(bundle: bundle)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var name = source.lastPathComponent
        var target = assets.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: target.path) {
            if (try? Data(contentsOf: target)) == (try? Data(contentsOf: source)) { return name }
            name = "\(displayName(source.lastPathComponent)) \(index).\(source.pathExtension)"
            target = assets.appendingPathComponent(name)
            index += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return name
        } catch {
            return nil
        }
    }
}

/// Plays the chosen background track from the panel ("Play <name>" / "Stop <name>").
@MainActor
final class BackgroundAudioPreview: ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(url: URL, volume: Double) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = Float(volume)
        player.play()
        self.player = player
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.player?.isPlaying != true { self?.stop() }
            }
        }
    }

    func toggle(url: URL, volume: Double) {
        if isPlaying { stop() } else { play(url: url, volume: volume) }
    }

    func setVolume(_ volume: Double) {
        player?.volume = Float(volume)
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }
}
