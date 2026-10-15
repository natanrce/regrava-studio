import AppKit
import Combine
import RegravaCore
import RegravaRender
import SwiftUI

/// Export state for one project window: the picker overlay, the running export and its progress.
@MainActor
final class ExportController: ObservableObject {
    struct Job {
        var projectName: String
        var outputPath: String?
        var progress: Double = 0
        var startedAt = Date()
        var error: String?
    }

    @Published var isPickerOpen = false
    @Published private(set) var job: Job?

    private let preferences = Preferences.shared
    private var task: Task<Void, Never>?
    private let dockProgress = DockProgress()

    var isExporting: Bool { job != nil }

    /// Folder for clipboard exports ("Show previous clipboard exports").
    static var clipboardExportsFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.natanzin.regravastudio")
            .appendingPathComponent("Clipboard Exports", isDirectory: true)
    }

    func openPicker() {
        guard !isExporting else { return }
        isPickerOpen = true
    }

    /// Primary action of the picker, or quick export with the widget settings.
    func start(project: Project, videoURL: URL, projectName: String, settings: ExportSettings, target: ExportTarget) {
        guard !isExporting else { return }
        let outputURL: URL
        switch target {
        case .file:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(projectName).\(settings.format.fileExtension)"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            outputURL = url
        case .clipboard:
            let folder = Self.clipboardExportsFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            outputURL = folder.appendingPathComponent("\(projectName) \(stamp).\(settings.format.fileExtension)")
        case .link:
            Dialogs.info(title: "Can't create shareable link", message: "Shareable links are not available in Regrava Studio.")
            return
        }

        isPickerOpen = false
        job = Job(projectName: projectName, outputPath: outputURL.path)
        dockProgress.show(0)
        // The controller is main-actor isolated; holding it strongly for the export is fine.
        task = Task {
            do {
                let files = try await ProjectExporter.export(
                    project: project, videoURL: videoURL, settings: settings, target: target, to: outputURL
                ) { value in
                    Task { @MainActor in self.update(progress: value) }
                }
                if target == .clipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(files.map { $0 as NSURL })
                }
                finish(error: nil)
            } catch is CancellationError {
                finish(error: nil)
            } catch ExportError.cancelled {
                finish(error: nil)
            } catch {
                finish(error: error.localizedDescription)
            }
        }
    }

    private func update(progress: Double) {
        guard job != nil else { return }
        job?.progress = progress
        dockProgress.show(progress)
    }

    private func finish(error: String?) {
        dockProgress.hide()
        task = nil
        if let error {
            job?.error = error
            Dialogs.error("Something went wrong when exporting (\(error))")
        }
        job = nil
    }

    /// "Stop export" with the confirmation.
    func requestStop() {
        guard isExporting else { return }
        if Dialogs.confirm(
            title: "Stop export",
            message: "Are you sure you want to stop current export?",
            confirm: "Stop export",
            cancel: "Don't stop export"
        ) {
            task?.cancel()
        }
    }

    // MARK: Estimates
    // Approximations based on this app's encoder settings.

    static func estimate(settings: ExportSettings, canvas: Size2, durationMs: Double) -> (time: String, size: String) {
        let size = settings.outputSize(canvas: canvas)
        let seconds = durationMs / 1000
        let pixelsPerSecond = size.width * size.height * Double(settings.fps)
        var exportSeconds = pixelsPerSecond * seconds / 90_000_000
        if settings.format == .gif { exportSeconds *= 1.3 }

        func megabytes(_ bitsPerPixel: Double) -> Double { bitsPerPixel * pixelsPerSecond * seconds / 8 / 1_000_000 }
        let sizeText: String
        switch settings.format {
        case .mp4:
            let h264 = megabytes(ProjectExporter.bitsPerPixel(settings.quality))
            switch settings.codec {
            case .h264: sizeText = formatMB(h264)
            case .h265: sizeText = formatMB(h264 * 0.6)
            case .both: sizeText = "\(formatMB(h264)) H.264, \(formatMB(h264 * 0.6)) HEVC"
            }
        case .prores:
            let bpp: Double = switch settings.proresProfile {
            case .lt: 1.6
            case .standard: 2.4
            case .hq: 3.5
            case .p4444: 5.3
            }
            sizeText = formatMB(megabytes(bpp))
        case .gif:
            let low = megabytes(settings.quality == .studio ? 1.2 : 0.6)
            let high = low * 2.5
            sizeText = "\(formatNumber(low))–\(formatNumber(high))MB"
        }
        return (formatDuration(exportSeconds), sizeText)
    }

    private static func formatNumber(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    private static func formatMB(_ value: Double) -> String { "\(formatNumber(value))MB" }

    static func formatDuration(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.up)), 1)
        if s < 60 { return "\(s) second\(s == 1 ? "" : "s")" }
        if s < 3600 {
            let m = Int((Double(s) / 60).rounded(.up))
            return "\(m) minute\(m == 1 ? "" : "s")"
        }
        return "\(s / 3600) hours \((s % 3600) / 60) minutes"
    }
}

/// Progress bar on the Dock icon, in 2.5% steps.
@MainActor
final class DockProgress {
    private var indicator: NSProgressIndicator?
    private var lastValue = -1.0

    func show(_ value: Double) {
        let stepped = (value / 0.025).rounded(.down) * 0.025
        guard stepped != lastValue else { return }
        lastValue = stepped
        let tile = NSApp.dockTile
        if indicator == nil {
            let image = NSImageView(image: NSApp.applicationIconImage)
            let bar = NSProgressIndicator(frame: NSRect(x: 8, y: 6, width: tile.size.width - 16, height: 12))
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            image.addSubview(bar)
            tile.contentView = image
            indicator = bar
        }
        indicator?.doubleValue = stepped
        tile.display()
    }

    func hide() {
        indicator = nil
        lastValue = -1
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}
