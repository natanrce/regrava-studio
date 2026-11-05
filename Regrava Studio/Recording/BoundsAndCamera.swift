@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import QuartzCore
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
                // A display shows the recorded bounds only when they cover 70% of it (or of
                // themselves); otherwise it is covered whole.
                guard PickerRules.overlaps(bounds, displayFrame, ratio: PickerRules.boundsIndicatorOverlap) else {
                    if cover { view = AnyView(Color.black.opacity(0.4)) } else { continue }
                    panels.append(makePanel(screen: screen, view: view))
                    continue
                }
                let local = bounds.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
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
                    c.frame(width: size.width, height: max(rect.minY, 0))
                    c.frame(width: size.width, height: max(size.height - rect.maxY, 0)).offset(y: rect.maxY)
                    c.frame(width: max(rect.minX, 0), height: rect.height).offset(y: rect.minY)
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

/// Floating mirrored camera preview: 240 pt (square, radius 36) or the live frame's aspect
/// (radius 18), opened at the largest format within the maximum webcam height. It shows
/// "Camera is starting..." until the first frame (or the failure), then reveals the video.
/// Its position is remembered; it is draggable, not focusable and kept out of recordings.
@MainActor
final class CameraPreviewController {
    private weak var coordinator: RecordingCoordinator?
    private var panel: NSPanel?
    private var view: CameraPreviewView?
    private var session: AVCaptureSession?
    private var frames: CameraFrameWatcher?
    private var errorObserver: NSObjectProtocol?
    private var shown: (cameraID: String, square: Bool, maxHeight: Int)?
    private static let positionKey = "panel.camera-preview"

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    /// Window size for an aspect ratio (width / height).
    static func size(aspect: Double) -> NSSize {
        NSSize(width: (240 * max(aspect, 1)).rounded(), height: (240 / min(aspect, 1)).rounded())
    }

    func show(cameraID: String) {
        let square = Preferences.shared.webcamPreviewType == "square"
        let maxHeight = Preferences.shared.maximumWebcamHeight
        if let shown, shown.cameraID == cameraID, shown.square == square, shown.maxHeight == maxHeight, panel != nil { return }
        hide()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice(uniqueID: cameraID) else { return }
        shown = (cameraID, square, maxHeight)

        // Until a frame arrives the window has the default 16:9 shape.
        let size = Self.size(aspect: square ? 1 : 16.0 / 9)
        let radius: CGFloat = square ? 240 * 0.15 : 240 * 0.15 * 0.5

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .recordingPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none

        let session = AVCaptureSession()
        let view = CameraPreviewView(session: session, cornerRadius: radius)
        view.menuProvider = { [weak self] in self?.contextMenu() }
        view.onMoved = { [weak panel] in
            guard let panel else { return }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.positionKey)
        }
        panel.contentView = view
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.frame.contains(saved) }) {
            panel.setFrameOrigin(saved)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 100, y: frame.minY + 100))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        self.session = session

        do {
            if let format = CameraFormats.best(of: device, maxHeight: maxHeight) {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.failed("Could not open the camera.") }
            session.addInput(input)
        } catch {
            view.showFailure(error.localizedDescription)
            return
        }
        // The live frame gives the preview its size and reveals the video.
        let frames = CameraFrameWatcher { [weak self] dimensions in
            self?.frameArrived(dimensions)
        }
        if session.canAddOutput(frames.output) { session.addOutput(frames.output) }
        self.frames = frames
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            MainActor.assumeIsolated { self?.view?.showFailure(error?.localizedDescription ?? "Camera failed") }
        }
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func frameArrived(_ dimensions: CGSize) {
        guard let panel, let view, let shown else { return }
        if !shown.square, dimensions.height > 0 {
            let size = Self.size(aspect: dimensions.width / dimensions.height)
            if panel.frame.size != size {
                // Keep the top-left corner where it is.
                let top = panel.frame.maxY
                panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            }
        }
        view.reveal()
    }

    func hide() {
        if let session { DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() } }
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        session = nil
        frames = nil
        shown = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    private func contextMenu() -> NSMenu {
        let menu = MenuBuilder()
        menu.toggle("Full-frame webcam preview", isOn: Preferences.shared.webcamPreviewType == "original") { [weak self] on in
            Preferences.shared.webcamPreviewType = on ? "original" : "square"
            if let id = self?.shown?.cameraID {
                self?.hide()
                self?.show(cameraID: id)
            }
        }
        let showsPreview = coordinator?.showCameraPreview ?? true
        menu.item("Hide camera preview", checked: !showsPreview) { [weak self] in self?.coordinator?.showCameraPreview.toggle() }
        return menu.menu
    }
}

/// Reports the size of every frame whose size differs from the last one.
private final class CameraFrameWatcher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "regrava.camera.preview")
    private var last: CGSize?
    private let onSize: @MainActor (CGSize) -> Void

    init(onSize: @escaping @MainActor (CGSize) -> Void) {
        self.onSize = onSize
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard size != last else { return }
        last = size
        let onSize = self.onSize
        DispatchQueue.main.async { MainActor.assumeIsolated { onSize(size) } }
    }
}

/// Mirrored live camera layer with rounded corners, the starting/failure text and a
/// right-click menu.
private final class CameraPreviewView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var onMoved: (() -> Void)?
    private let preview: AVCaptureVideoPreviewLayer
    private let status: NSHostingView<CameraPreviewStatus>
    private let statusModel = CameraPreviewStatusModel()
    private var revealed = false

    init(session: AVCaptureSession, cornerRadius: CGFloat) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        status = NSHostingView(rootView: CameraPreviewStatus(model: statusModel))
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor(Theme.Colors.backgroundAccent).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        // Hidden, blurred and enlarged until the first frame.
        preview.opacity = 0
        preview.setAffineTransform(Self.transform(scale: 1.5))
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 20]) {
            blur.name = "blur"
            preview.filters = [blur]
        }
        layer?.addSublayer(preview)
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.topAnchor.constraint(equalTo: topAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Mirrored, scaled about the center.
    private static func transform(scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: -scale, y: scale)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = preview.affineTransform()
        preview.setAffineTransform(.identity)
        preview.frame = bounds
        preview.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// Opacity 0→1, blur 20→0 and scale 1.5→1 over 0.6 s.
    func reveal() {
        statusModel.state = .running
        guard !revealed else { return }
        revealed = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.32, 0.9, 0.45, 1.01))
        preview.opacity = 1
        preview.setAffineTransform(Self.transform(scale: 1))
        preview.setValue(0, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
    }

    func showFailure(_ message: String) {
        statusModel.state = .failed(message)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onMoved?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

@MainActor
private final class CameraPreviewStatusModel: ObservableObject {
    enum State: Equatable {
        case starting, running, failed(String)
    }

    @Published var state = State.starting
}

/// "Camera is starting..." blinking (opacity 0.5–1 over 1.5 s), or the failure, centered on
/// the accent background, at most 150 pt wide.
private struct CameraPreviewStatus: View {
    @ObservedObject var model: CameraPreviewStatusModel

    var body: some View {
        Group {
            switch model.state {
            case .starting:
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                    let wave = 0.5 - 0.5 * cos(2 * .pi * t)
                    label("Camera is starting...").opacity(0.5 + 0.5 * wave)
                }
            case .failed(let message):
                label(message)
            case .running:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.state == .running ? Color.clear : Theme.Colors.backgroundAccent)
        .allowsHitTesting(false)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.copy)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.Colors.text)
            .frame(maxWidth: 150)
    }
}
