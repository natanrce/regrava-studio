@preconcurrency import AVFoundation
import AppKit
import RegravaCapture
import SwiftUI

// MARK: - Recording bounds indicator

/// While recording: dims everything that is not recorded. For an area/window the dashed
/// border is shown only when the cover is off; for a display, other displays are covered.
@MainActor
final class BoundsIndicatorController {
    private var panels: [NSPanel] = []
    private var shown: (CGRect, Bool)?

    func show(selection: RecordSelection, cover: Bool) {
        guard let bounds = selection.globalBounds else { return }
        if let shown, shown.0 == bounds, shown.1 == cover { return }
        hide()
        shown = (bounds, cover)
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let displayFrame = CGDisplayBounds(id)
            let view: AnyView
            if case .display(let display) = selection {
                guard display.id != id, cover else { continue }
                view = AnyView(Color.black.opacity(0.4))
            } else {
                let overlap = displayFrame.intersection(bounds)
                guard !overlap.isNull else {
                    if cover { view = AnyView(Color.black.opacity(0.4)) } else { continue }
                    panels.append(makePanel(screen: screen, view: view))
                    continue
                }
                let local = overlap.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
                view = AnyView(BoundsMask(rect: local, cover: cover))
            }
            panels.append(makePanel(screen: screen, view: view))
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        shown = nil
    }

    private func makePanel(screen: NSScreen, view: AnyView) -> NSPanel {
        let panel = OverlayPanel(screen: screen)
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        return panel
    }
}

private struct BoundsMask: View {
    var rect: CGRect
    var cover: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if cover {
                    let c = Color.black.opacity(0.4)
                    c.frame(width: size.width, height: rect.minY)
                    c.frame(width: size.width, height: max(size.height - rect.maxY, 0)).offset(y: rect.maxY)
                    c.frame(width: rect.minX, height: rect.height).offset(y: rect.minY)
                    c.frame(width: max(size.width - rect.maxX, 0), height: rect.height).offset(x: rect.maxX, y: rect.minY)
                } else {
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.white.opacity(0x44 / 255))
                        .frame(width: rect.width + 2, height: rect.height + 2)
                        .offset(x: rect.minX - 1, y: rect.minY - 1)
                }
            }
        }
    }
}

// MARK: - Camera preview

/// Floating mirrored camera preview: 240 px (square, radius 36) or camera aspect (radius 18),
/// bottom-right 100 px from the edges, draggable, not focusable, kept out of recordings.
@MainActor
final class CameraPreviewController {
    private weak var coordinator: RecordingCoordinator?
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var cameraID: String?
    private var squared: Bool?

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    func show(cameraID: String) {
        let square = Preferences.shared.webcamPreviewType == "square"
        if self.cameraID == cameraID, squared == square, panel != nil { return }
        hide()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice(uniqueID: cameraID),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        self.session = session
        self.cameraID = cameraID
        squared = square

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let aspect = square ? 1 : (dimensions.height > 0 ? Double(dimensions.width) / Double(dimensions.height) : 16.0 / 9)
        let size = NSSize(width: 240 * max(aspect, 1), height: 240 / min(aspect, 1))
        let radius: CGFloat = square ? 240 * 0.15 : 18

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .recordingPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none

        let view = CameraPreviewView(session: session, cornerRadius: radius)
        view.menuProvider = { [weak self] in self?.contextMenu() }
        panel.contentView = view
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 100, y: frame.minY + 100))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func hide() {
        if let session { DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() } }
        session = nil
        cameraID = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func contextMenu() -> NSMenu {
        let menu = MenuBuilder()
        menu.toggle("Full-frame webcam preview", isOn: Preferences.shared.webcamPreviewType == "original") { [weak self] on in
            Preferences.shared.webcamPreviewType = on ? "original" : "square"
            if let id = self?.cameraID {
                self?.hide()
                self?.show(cameraID: id)
            }
        }
        menu.item("Hide camera preview") { [weak self] in self?.coordinator?.showCameraPreview = false }
        return menu.menu
    }
}

/// Mirrored live camera layer with rounded corners and a right-click menu.
private final class CameraPreviewView: NSView {
    var menuProvider: (() -> NSMenu?)?

    init(session: AVCaptureSession, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.Colors.backgroundAccent).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(preview)
        preview.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
