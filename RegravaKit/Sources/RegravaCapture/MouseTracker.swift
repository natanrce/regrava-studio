import AppKit
import CoreGraphics
import RegravaCore

/// Records cursor position and type (polled) and button events (event monitors) while recording.
///
/// Times are `ProcessInfo.systemUptime` seconds, the same clock as `NSEvent.timestamp`,
/// so they can be aligned with the moment the recording output started writing.
@MainActor
final class MouseTracker {
    struct Sample {
        var kind: MouseEventKind
        var uptime: TimeInterval
        /// Global display coordinates in points, top-left origin (Quartz space).
        var location: CGPoint
        var button: Int
        var cursorID: String?
    }

    private var samples: [Sample] = []
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastLocation: CGPoint?
    private var lastCursorID: String?
    private var pollCount = 0
    private let cursors = CursorIdentifier()

    /// Cursor images that are not standard system cursors, by id.
    var customCursors: [CapturedCursorImage] { cursors.customImages }

    func start(pollHz: Double = 120) {
        stop()
        samples.removeAll()
        lastLocation = nil
        lastCursorID = nil
        pollCount = 0
        cursors.reset()
        poll()

        let timer = Timer(timeInterval: 1 / pollHz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    @discardableResult
    func stop() -> [Sample] {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        return samples
    }

    private func poll() {
        guard let location = CGEvent(source: nil)?.location else { return }
        // The cursor type is sampled at 30 Hz; position at the poll rate.
        if pollCount % 4 == 0 { lastCursorID = cursors.currentID() ?? lastCursorID }
        pollCount += 1
        let cursorChanged = samples.last.map { $0.cursorID != lastCursorID } ?? true
        guard location != lastLocation || cursorChanged else { return }
        lastLocation = location
        // Movement while a button is held is a drag ("mouseDragged").
        let kind: MouseEventKind = NSEvent.pressedMouseButtons != 0 ? .drag : .move
        samples.append(Sample(kind: kind, uptime: ProcessInfo.processInfo.systemUptime, location: location, button: 0, cursorID: lastCursorID))
    }

    private func record(_ event: NSEvent) {
        let kind: MouseEventKind
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up
        default: return
        }
        let location = event.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
        lastCursorID = cursors.currentID() ?? lastCursorID
        samples.append(Sample(kind: kind, uptime: event.timestamp, location: location, button: event.buttonNumber, cursorID: lastCursorID))
    }
}
