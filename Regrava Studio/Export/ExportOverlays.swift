import AppKit
import RegravaCore
import SwiftUI

/// Export picker ("ProjectExportStarter").
struct ExportPickerOverlay: View {
    @ObservedObject var exports: ExportController
    @ObservedObject var preferences = Preferences.shared
    var project: Project
    var projectName: String
    var videoURL: URL

    private var store: Binding<ExportSettingsStore> { $preferences.exportSettings }

    /// The link target is not offered (no shareable-link service).
    private let targets: [ExportTarget] = [.file, .clipboard]

    private var target: ExportTarget {
        targets.contains(preferences.exportSettings.preferredTarget) ? preferences.exportSettings.preferredTarget : targets[0]
    }

    var body: some View {
        ZStack {
            Theme.Colors.background.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture {}
            ScrollView {
                VStack(spacing: Theme.gap(2)) {
                    card
                    footer
                }
                .frame(maxWidth: 740)
                .padding(80)
                .frame(maxWidth: .infinity)
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
        .onExitCommand { exports.isPickerOpen = false }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.gap(3.5)) {
            ExportSettingsForm(store: store, target: target, aspectRatio: project.stageAspectRatio)
            NamedField(name: "Export to") {
                HStack(spacing: Theme.gap(1)) {
                    SegmentedPicker(
                        options: targets,
                        label: { Self.targetLabel($0) },
                        icon: { Self.targetIcon($0) },
                        size: .big,
                        selection: Binding(get: { target }, set: { preferences.exportSettings.preferredTarget = $0 })
                    )
                    if target == .clipboard {
                        RSButton(title: "Show previous clipboard exports", icon: "folder", kind: .secondary, size: .big) {
                            let folder = ExportController.clipboardExportsFolder
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                    Spacer(minLength: 0)
                    RSButton(title: Self.primaryLabel(target), icon: Self.targetIcon(target), kind: .primary, size: .big) {
                        exports.start(
                            project: project,
                            videoURL: videoURL,
                            projectName: projectName,
                            settings: preferences.exportSettings.current,
                            target: target
                        )
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    RSButton(title: "Cancel", kind: .secondary, size: .big) { exports.isPickerOpen = false }
                }
            }
        }
        .padding(32)
        .frame(width: 740)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.Colors.popover)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        let settings = preferences.exportSettings.current
        let estimate = ExportEstimator.texts(
            settings: settings.normalized(target: target), target: target, aspectRatio: project.stageAspectRatio,
            durationMs: project.playbackDurationMs, hasAudio: project.exportHasAudio
        )
        return HStack(alignment: .top, spacing: Theme.gap(0.5)) {
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Estimation — Export time \(estimate.time) — Output size \(estimate.size)")
                if settings.format == .gif {
                    Text("GIF files are much larger than MP4 files. Use MP4 when you can.")
                }
                if settings.format == .prores {
                    Text("ProRes is made for editing apps. Use MP4 to share.")
                }
            }
            .font(Theme.Typo.label)
            .multilineTextAlignment(.trailing)
            .opacity(0.2)
        }
    }

    static func targetLabel(_ target: ExportTarget) -> String {
        switch target {
        case .file: return "File"
        case .clipboard: return "Clipboard"
        case .link: return "Shareable link"
        }
    }

    static func targetIcon(_ target: ExportTarget) -> String {
        switch target {
        case .file: return "square.and.arrow.up.fill"
        case .clipboard: return "document.on.clipboard"
        case .link: return "link"
        }
    }

    static func primaryLabel(_ target: ExportTarget) -> String {
        switch target {
        case .file: return "Export to file..."
        case .clipboard: return "Export to clipboard"
        case .link: return "Export & Share"
        }
    }
}

/// Export progress ("ProjectExportStatus").
struct ExportStatusOverlay: View {
    @ObservedObject var exports: ExportController

    var body: some View {
        if let job = exports.job {
            // The clock ticks every second.
            TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                ExportStatusContent(exports: exports, tasks: exports.tasks ?? Self.noTasks, job: job, now: context.date)
            }
        }
    }

    private static let noTasks = BackgroundTasks()
}

private struct ExportStatusContent: View {
    @ObservedObject var exports: ExportController
    @ObservedObject var tasks: BackgroundTasks
    var job: ExportController.Job
    var now: Date

    var body: some View {
        let nowMs = now.timeIntervalSince1970 * 1000
        let elapsedMs = job.estimator.elapsedMs(nowMs: nowMs)
        let timeLeftMs = job.estimator.timeLeftMs(nowMs: nowMs, isPaused: !tasks.tasks.isEmpty)
        let decimals = ExportProgressText.percentDecimals(totalMs: elapsedMs + (timeLeftMs ?? 0))
        return ZStack {
            Theme.Colors.background.ignoresSafeArea()
            VStack(spacing: Theme.gap(4)) {
                VStack(spacing: Theme.gap(1)) {
                    HStack(spacing: 0) {
                        Text(job.error != nil ? "Export failed" : "Exporting video")
                        Text("\u{00a0}•\u{00a0}")
                        Text(ExportProgressText.percent(job.progress, decimals: decimals))
                        if let path = job.outputPath {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16))
                                .opacity(0.5)
                                .padding(.leading, 4)
                                .tooltip("\(job.projectName).\(ProjectStore.fileExtension) → \(path)")
                        }
                    }
                    .font(Theme.Typo.title)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.bottom, 4)
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.Colors.primary)
                    Text(Self.status(progress: job.progress, elapsedMs: elapsedMs, timeLeftMs: timeLeftMs))
                        .font(Theme.Typo.copy)
                        .monospacedDigit()
                        .lineLimit(1)
                        .opacity(Theme.secondaryOpacity)
                    if !tasks.shown.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.gap(1)) {
                            ForEach(tasks.shown, id: \.key) { BackgroundTaskRow(task: $0) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: 320)
                RSButton(title: "Stop export", kind: .secondary, size: .big) { exports.requestStop() }
            }
            .padding(20)
        }
        .transition(.opacity)
    }

    static func status(progress: Double, elapsedMs: Double, timeLeftMs: Double?) -> String {
        guard progress > 0 else { return "Preparing export..." }
        let left = timeLeftMs.map { "\(ExportProgressText.duration(ms: $0)) left" } ?? "Estimating time left..."
        return "\(ExportProgressText.duration(ms: elapsedMs)) • \(left)"
    }
}
