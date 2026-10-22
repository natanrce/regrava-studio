import AVFoundation
import AppKit
import Combine
import RegravaCore
import SwiftUI

// "Recent Projects": a full-width strip at the top of the screen next to the record picker,
// while no source is chosen yet.

/// A project in the strip.
struct RecentProject: Identifiable, Hashable {
    var url: URL
    var name: String
    var lastOpened: Date?
    var modified: Date?
    var previewURL: URL?

    var id: URL { url }

    static func load(_ url: URL, lastOpened: Date?) -> RecentProject {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let preview = ProjectPreview.url(bundle: url)
        return RecentProject(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            lastOpened: lastOpened,
            modified: values?.contentModificationDate,
            previewURL: FileManager.default.fileExists(atPath: preview.path) ? preview : nil
        )
    }
}

/// A rendered frame saved with the project (`previewImagePath`), shown on the project cards.
enum ProjectPreview {
    static func url(bundle: URL) -> URL { bundle.appendingPathComponent("preview.jpg") }

    /// Draws `time` of the editor's composition (styled, as in the preview) into the bundle.
    static func write(asset: AVAsset, videoComposition: AVVideoComposition?, time: CMTime, to bundle: URL) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let image = try? await generator.image(at: time).image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? data.write(to: url(bundle: bundle), options: .atomic)
    }
}

@MainActor
final class RecentProjectsModel: ObservableObject {
    @Published var search = ""
    @Published private(set) var projects: [RecentProject] = []
    @Published var openingURL: URL?

    func reload() {
        let opened = UserDefaults.standard.dictionary(forKey: "recentProjectsOpenedAt") as? [String: Double] ?? [:]
        projects = AppController.shared.recentProjects.map {
            RecentProject.load($0, lastOpened: opened[$0.path].map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Case-insensitive name match.
    var filtered: [RecentProject] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    func remove(_ project: RecentProject) {
        AppController.shared.removeRecent(project.url)
        reload()
    }
}

/// The strip's window: top of the screen under the mouse, full width, 280 tall, sidebar
/// vibrancy, fading in after 100 ms; Escape closes it.
final class RecentProjectsPanel: NSPanel {
    let model = RecentProjectsModel()
    private var onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 280), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        level = .recordingPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: RecentProjectsView(model: model, close: { [weak self] in self?.closeStrip() }).environment(\.colorScheme, .dark))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { closeStrip() }

    func closeStrip() { onClose() }

    func present() {
        model.reload()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.frame {
            setFrame(NSRect(x: frame.minX, y: frame.maxY - 280, width: frame.width, height: 280), display: true)
        }
        guard !isVisible else { return }
        alphaValue = 0
        orderFrontRegardless()
        // Opacity springs in after 100 ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.animator().alphaValue = 1
            }
        }
    }
}

struct RecentProjectsView: View {
    @ObservedObject var model: RecentProjectsModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                RSIconButton(icon: "xmark.circle.fill", kind: .transparent, size: .large) { close() }
                Spacer()
                HStack(spacing: 8) {
                    RSButton(title: "Show previous projects", icon: "folder", kind: .secondary) {
                        AppController.shared.showPreviousProjects()
                        close()
                    }
                    RSButton(title: "Open project...", icon: "folder", kind: .secondary) {
                        close()
                        AppController.shared.openProjectPanel()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    SearchField(text: $model.search) {
                        if let first = model.filtered.first { open(first) }
                    }
                    .frame(width: 320)
                }
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
            body(for: model.filtered)
                .padding(EdgeInsets(top: 4, leading: 24, bottom: 20, trailing: 24))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colors.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func body(for projects: [RecentProject]) -> some View {
        if model.projects.isEmpty {
            empty(icon: "video.fill", title: "No projects yet", text: "Projects you record or open will show up here.")
        } else if projects.isEmpty {
            empty(icon: "magnifyingglass", title: "No recent projects match “\(model.search)”", text: nil)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(projects) { project in
                        RecentProjectCard(project: project, isOpening: model.openingURL == project.url, isDimmed: model.openingURL != nil && model.openingURL != project.url) {
                            open(project)
                        } onRemove: {
                            model.remove(project)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, -24)
        }
    }

    private func empty(icon: String, title: String, text: String?) -> some View {
        VStack(spacing: 11.3) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Theme.Colors.tertiary)
            Text(title).font(Theme.Typo.copy.weight(.medium))
            if let text {
                Text(text).font(Theme.Typo.label).foregroundStyle(Color.white.opacity(Theme.secondaryOpacity)).frame(maxWidth: 340).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 48, leading: 24, bottom: 48, trailing: 24))
    }

    private func open(_ project: RecentProject) {
        model.openingURL = project.url
        DispatchQueue.main.async {
            close()
            AppController.shared.recording.closePicker()
            AppController.shared.openProject(at: project.url)
            model.openingURL = nil
        }
    }
}

/// Card: a 16:10 thumbnail with a 1 px border (primary at 0.75 on hover, 0.985 when
/// pressed), then the name and when it was last opened.
private struct RecentProjectCard: View {
    var project: RecentProject
    var isOpening: Bool
    var isDimmed: Bool
    var action: () -> Void
    var onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5.7) {
                thumbnail
                    .aspectRatio(16.0 / 10, contentMode: .fit)
                    .frame(width: 240)
                    .background(Theme.Colors.lighterBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Theme.Colors.primary.opacity(0.75) : Theme.Colors.systemBorder, lineWidth: 1))
                    .overlay {
                        if isOpening {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                HStack(spacing: 8) {
                    Text(project.name).font(Theme.Typo.copy.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(Self.detail(project.lastOpened ?? project.modified)).font(Theme.Typo.copy).foregroundStyle(Color.white.opacity(Theme.secondaryOpacity)).lineLimit(1).fixedSize()
                }
                .frame(width: 240)
            }
        }
        .buttonStyle(CardPressStyle())
        .opacity(isDimmed ? 0.5 : 1)
        .allowsHitTesting(!isDimmed)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            if project.lastOpened != nil { Button("Remove from Recents", action: onRemove) }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = project.previewURL, let image = NSImage(contentsOf: url) {
            Color.clear.overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)).clipped()
        } else {
            Color.clear.overlay(Image(systemName: "video.fill").font(.system(size: 28)).foregroundStyle(Theme.Colors.tertiary))
        }
    }

    /// Date format: "Today", "Yesterday", else the medium date.
    static func detail(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1).contentShape(Rectangle())
    }
}

/// "Search projects" field; Return runs `onSubmit`.
private struct SearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.tertiary)
            TextField("Search projects", text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
        }
        .font(Theme.Typo.controlCopy)
        .padding(.horizontal, 12)
        .frame(height: Theme.Boxes.control.height)
        .background(RoundedRectangle(cornerRadius: Theme.Boxes.control.radius).fill(Theme.Colors.lighterBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Boxes.control.radius).strokeBorder(Theme.Colors.systemBorder, lineWidth: 1))
    }
}
