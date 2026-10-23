import AppKit
import Combine
import SwiftUI

// Speaker notes: a prompter window shown while `showSpeakerNotes` is on, whatever else is open.

/// The note and the prompter settings, each kept under the key.
@MainActor
final class SpeakerNotesStore: ObservableObject {
    static let shared = SpeakerNotesStore()
    static let defaultFontSize = 14.0

    @Published var content: String { didSet { defaults.set(content, forKey: "speakerNoteContent") } }
    @Published var prompterSpeed: Double { didSet { defaults.set(prompterSpeed, forKey: "speakerNotesPrompterSpeed") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "speakerNotesOpacity") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "speakerNotesFontSize") } }
    /// In memory only; it survives the window closing.
    @Published var isPlaying = false

    private let defaults = UserDefaults.standard

    private init() {
        content = defaults.string(forKey: "speakerNoteContent") ?? ""
        prompterSpeed = defaults.object(forKey: "speakerNotesPrompterSpeed") as? Double ?? 5
        opacity = defaults.object(forKey: "speakerNotesOpacity") as? Double ?? 1
        fontSize = defaults.object(forKey: "speakerNotesFontSize") as? Double ?? Self.defaultFontSize
    }

    func togglePlaying() { isPlaying.toggle() }

    /// The speed is px/s at a 14 px font.
    var pixelsPerSecond: Double { prompterSpeed * (fontSize / 14) }
}

/// 240×320 floating panel (240–480 × 240–620), titled with inset traffic lights, vibrant,
/// always on top, its opacity from the store, its frame remembered under "speaker-notes".
@MainActor
final class SpeakerNotesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SpeakerNotesWindowController()
    private var cancellables: Set<AnyCancellable> = []
    private var isClosingFromSetting = false

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "speaker-notes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 240, height: 240)
        panel.contentMaxSize = NSSize(width: 480, height: 620)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: SpeakerNotesView(store: .shared).environment(\.colorScheme, .dark))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        super.init(window: panel)
        panel.delegate = self
        if !panel.setFrameUsingName("speaker-notes") { panel.center() }
        panel.setFrameAutosaveName("speaker-notes")
        SpeakerNotesStore.shared.$opacity
            .sink { [weak panel] in panel?.alphaValue = $0 }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Follows the setting.
    func apply(_ visible: Bool) {
        guard let window else { return }
        if visible {
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            positionTrafficLights()
        } else if window.isVisible {
            isClosingFromSetting = true
            window.orderOut(nil)
            isClosingFromSetting = false
        }
    }

    /// Kept out of the recording only while one is in progress (`contentProtection: "while-recording"`).
    func setRecording(_ recording: Bool) {
        window?.sharingType = recording ? .none : .readOnly
    }

    /// The close button turns the setting off.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Preferences.shared.showSpeakerNotes = false
        return false
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }

    /// Traffic lights at (23, 22) of a 60 px bar, like the tool windows.
    private func positionTrafficLights() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let titlebarView = close.superview, let container = titlebarView.superview else { return }
        let height: CGFloat = 60
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        titlebarView.frame = container.bounds
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 23 + CGFloat(index) * 20, y: height - 22 - button.frame.height))
        }
    }
}

struct SpeakerNotesView: View {
    @ObservedObject var store: SpeakerNotesStore
    @ObservedObject private var preferences = Preferences.shared
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // 60 px toolbar, buttons on the right of the traffic lights.
            HStack(spacing: Theme.gap(1)) {
                Spacer(minLength: 0)
                let shortcut = (preferences.shortcuts[.toggleSpeakerNotesPrompter] ?? nil)?.display ?? ""
                RSIconButton(icon: store.isPlaying ? "pause" : "play", kind: .secondary, size: .toolbar,
                             tooltip: "Toggle speaker notes prompter" + (shortcut.isEmpty ? "" : "  \(shortcut)")) { store.togglePlaying() }
                RSIconButton(icon: "gear", kind: .secondary, size: .toolbar, tooltip: "Settings") { showsSettings.toggle() }
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) { settings }
            }
            .padding(.leading, 90)
            .padding(.trailing, 14)
            .frame(height: 60)
            SpeakerNotesText(store: store)
        }
        .background(Theme.Colors.background.opacity(0.6))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.gap(2)) {
            NamedField(name: "Prompter Speed", icon: "gauge.with.dots.needle.67percent") {
                RSSlider(value: $store.prompterSpeed, range: 0...25)
            }
            NamedField(name: "Notepad opacity", icon: "circle.righthalf.filled") {
                RSSlider(value: $store.opacity, range: 0.4...1)
            }
            NamedField(name: "Font size", icon: "textformat.size") {
                HStack(spacing: Theme.gap(1)) {
                    RSSlider(value: $store.fontSize, range: 12...32)
                    RSButton(title: "Reset", kind: .secondary) { store.fontSize = SpeakerNotesStore.defaultFontSize }
                        .disabled(store.fontSize == SpeakerNotesStore.defaultFontSize)
                }
            }
        }
        .frame(minWidth: 140)
        .padding(Theme.gap(2))
        .environment(\.colorScheme, .dark)
    }
}

/// The note: a plain text view that scrolls itself while the prompter plays: a 60 Hz timer adds
/// speed/60 px to its own position until the bottom; the position re-syncs to the view only on
/// wheel scrolls and resizes.
private struct SpeakerNotesText: NSViewRepresentable {
    @ObservedObject var store: SpeakerNotesStore

    final class Coordinator: NSObject, NSTextViewDelegate {
        var store: SpeakerNotesStore?
        weak var scrollView: NSScrollView?
        var timer: Timer?
        var position: CGFloat = 0
        var speed: Double = 0
        var observers: [Any] = []

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { store?.content = view.string }
        }

        func sync() { position = scrollView?.contentView.bounds.origin.y ?? 0 }

        func run(playing: Bool, speed: Double) {
            guard playing != (timer != nil) || speed != self.speed else { return }
            timer?.invalidate()
            timer = nil
            self.speed = speed
            guard playing else { return }
            sync()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            guard clip.bounds.maxY < document.frame.height else { return }
            position += CGFloat(speed / 60)
            clip.scroll(to: NSPoint(x: 0, y: min(position, max(document.frame.height - clip.bounds.height, 0))))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        let text = scrollView.documentView as! NSTextView
        text.isRichText = false
        text.drawsBackground = false
        text.allowsUndo = true
        text.textContainerInset = NSSize(width: 22, height: 10)
        text.textContainer?.lineFragmentPadding = 0
        text.insertionPointColor = .white
        text.string = store.content
        text.delegate = context.coordinator
        text.isAutomaticQuoteSubstitutionEnabled = false
        context.coordinator.store = store
        context.coordinator.scrollView = scrollView
        let center = NotificationCenter.default
        let coordinator = context.coordinator
        context.coordinator.observers = [
            center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main) { _ in coordinator.sync() },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { _ in coordinator.sync() },
        ]
        scrollView.postsFrameChangedNotifications = true
        style(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let text = scrollView.documentView as? NSTextView else { return }
        style(text)
        context.coordinator.run(playing: store.isPlaying, speed: store.pixelsPerSecond)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Font size, 1.5 line height, 20 px bottom padding and the placeholder.
    private func style(_ text: NSTextView) {
        let font = NSFont.systemFont(ofSize: store.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = store.fontSize * 1.5
        paragraph.maximumLineHeight = store.fontSize * 1.5
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        if text.font != font {
            text.font = font
            text.typingAttributes = attributes
            if let storage = text.textStorage { storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length)) }
        }
        text.setValue(NSAttributedString(string: "Enter your notes here. This window will not be visible in the final recording...",
                                         attributes: [.font: font, .foregroundColor: NSColor(Theme.Colors.tertiary)]), forKey: "placeholderAttributedString")
        text.textContainer?.size.height = .greatestFiniteMagnitude
        text.textContainerInset = NSSize(width: 22, height: 10)
        text.enclosingScrollView?.contentInsets.bottom = 10
    }
}
