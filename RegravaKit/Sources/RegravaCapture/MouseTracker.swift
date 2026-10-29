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
        var modifiers: [KeyModifier]
    }

    struct KeySample {
        var kind: Keystroke.Kind
        var uptime: TimeInterval
        var character: String
        var modifiers: [KeyModifier]
        var isARepeat: Bool
    }

    /// Cursor of the last sample written (`.none` before the first).
    private var lastSampledCursorID: String??
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastLocation: CGPoint?
    private var lastCursorID: String?
    private var pollCount = 0
    private let cursors = CursorIdentifier()
    /// Where samples are written as they come (the recording folder's event logs).
    var journal: RecordingJournal?
    private var savedCursorCount = 0

    func start(pollHz: Double = 120) {
        stop()
        lastSampledCursorID = .none
        lastLocation = nil
        lastCursorID = nil
        pollCount = 0
        cursors.reset()
        savedCursorCount = 0
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

        // Keystrokes (global monitoring needs the Accessibility permission from onboarding).
        let keys: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: keys, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordKey(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: keys, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordKey(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func poll() {
        guard let location = CGEvent(source: nil)?.location else { return }
        // The cursor type is sampled at 30 Hz; position at the poll rate.
        if pollCount % 4 == 0 { lastCursorID = cursors.currentID() ?? lastCursorID }
        pollCount += 1
        let cursorChanged = lastSampledCursorID.map { $0 != lastCursorID } ?? true
        guard location != lastLocation || cursorChanged else { return }
        lastLocation = location
        // Movement while a button is held is a drag ("mouseDragged").
        let kind: MouseEventKind = NSEvent.pressedMouseButtons != 0 ? .drag : .move
        add(Sample(kind: kind, uptime: ProcessInfo.processInfo.systemUptime, location: location, button: 0, cursorID: lastCursorID, modifiers: Self.modifiers(NSEvent.modifierFlags)))
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
        add(Sample(kind: kind, uptime: event.timestamp, location: location, button: event.buttonNumber, cursorID: lastCursorID, modifiers: Self.modifiers(event.modifierFlags)))
    }

    /// `character` is the key ignoring modifiers except Shift, so ⌘⇧4 is "$" with command and
    /// shift, as the tables expect.
    private func recordKey(_ event: NSEvent) {
        let sample = KeySample(
            kind: event.type == .keyDown ? .down : .up,
            uptime: event.timestamp,
            character: event.charactersIgnoringModifiers ?? "",
            modifiers: Self.modifiers(event.modifierFlags),
            isARepeat: event.isARepeat
        )
        journal?.record(sample)
    }

    private func add(_ sample: Sample) {
        lastSampledCursorID = .some(sample.cursorID)
        journal?.record(sample)
        let custom = cursors.customImages
        if custom.count != savedCursorCount {
            savedCursorCount = custom.count
            journal?.saveCursors(custom)
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> [KeyModifier] {
        var out: [KeyModifier] = []
        if flags.contains(.command) { out.append(.command) }
        if flags.contains(.option) { out.append(.option) }
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.capsLock) { out.append(.capsLock) }
        if flags.contains(.function) { out.append(.function) }
        return out
    }
}
