import AppKit
import CoreGraphics
import RegravaCore

/// Records cursor position (polled) and button events (event monitors) while recording.
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
    }

    private var samples: [Sample] = []
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastLocation: CGPoint?

    func start(pollHz: Double = 120) {
        stop()
        samples.removeAll()
        lastLocation = nil
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
        guard location != lastLocation else { return }
        lastLocation = location
        samples.append(Sample(kind: .move, uptime: ProcessInfo.processInfo.systemUptime, location: location, button: 0))
    }

    private func record(_ event: NSEvent) {
        let kind: MouseEventKind
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up
        default: return
        }
        let location = event.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
        samples.append(Sample(kind: kind, uptime: event.timestamp, location: location, button: event.buttonNumber))
    }
}
