import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: CGDirectDisplayID
    /// Localized screen name ("Built-in Retina Display").
    public var label: String
    /// Global frame in points, top-left origin (Quartz space).
    public var frame: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Int
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    public var appPath: String?
    public var bundleIdentifier: String
    /// Global frame in points, top-left origin.
    public var frame: CGRect
    public var processID: pid_t
    /// Corner radius of the window, in points.
    public var borderRadius: Double = 10
}

/// Capturable displays and windows.
public enum CaptureCatalog {
    /// Windows never offered by the window picker.
    static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui",
        "pl.maketheweb.cleanshotx",
        "com.apple.loginwindow",
        "com.apple.screencaptureui",
        "com.apple.screencapture",
        "com.getcleanshot.app-setapp",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
    ]

    /// Displays, and on-screen application windows front-most first, from one query.
    public static func sources() async throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let displays = await MainActor.run { content.displays.map(describe) }
        return (displays, windows(in: content))
    }

    static func windows(in content: SCShareableContent) -> [WindowInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let order = frontToBackWindowIDs()
        let windows = content.windows.compactMap { window -> WindowInfo? in
            guard window.windowLayer == 0, window.isOnScreen,
                  let app = window.owningApplication,
                  app.processID != ownPID,
                  !excludedBundleIdentifiers.contains(app.bundleIdentifier),
                  window.frame.width >= 40, window.frame.height >= 40 else { return nil }
            let path = NSRunningApplication(processIdentifier: app.processID)?.bundleURL?.path
            return WindowInfo(
                id: window.windowID,
                title: window.title ?? "",
                appName: app.applicationName,
                appPath: path,
                bundleIdentifier: app.bundleIdentifier,
                frame: window.frame,
                processID: app.processID,
                borderRadius: cornerRadius(id: window.windowID, processID: app.processID, title: window.title ?? "", frame: window.frame)
            )
        }
        return windows.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    /// The live window, or nil when it is no longer capturable.
    public static func window(id: CGWindowID) async -> WindowInfo? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        return windows(in: content).first { $0.id == id }
    }

    private static let radiusCache = RadiusCache()

    /// Radii already measured, by window, kept while the window keeps its frame.
    private final class RadiusCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CGWindowID: (frame: CGRect, radius: Double)] = [:]

        func radius(_ id: CGWindowID, frame: CGRect) -> Double? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[id], entry.frame == frame else { return nil }
            return entry.radius
        }

        func store(_ id: CGWindowID, frame: CGRect, radius: Double) {
            lock.lock()
            entries[id] = (frame, radius)
            lock.unlock()
        }
    }

    /// The window's corner radius from Accessibility, 10 when it has no Accessibility window.
    static func cornerRadius(id: CGWindowID, processID: pid_t, title: String, frame: CGRect) -> Double {
        if let cached = radiusCache.radius(id, frame: frame) { return cached }
        let radius = AccessibilityWindow.matching(processID: processID, title: title, frame: frame)?.cornerRadius ?? 10
        if AXIsProcessTrusted() { radiusCache.store(id, frame: frame, radius: radius) }
        return radius
    }

    @MainActor
    static func describe(_ display: SCDisplay) -> DisplayInfo {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let refresh = mode.map { $0.refreshRate > 0 ? Int($0.refreshRate.rounded()) : 60 } ?? 60
        return DisplayInfo(
            id: display.displayID,
            label: screen?.localizedName ?? "Display \(display.displayID)",
            frame: CGDisplayBounds(display.displayID),
            pixelWidth: mode?.pixelWidth ?? display.width,
            pixelHeight: mode?.pixelHeight ?? display.height,
            refreshRate: refresh
        )
    }

    /// Window stacking order from the window server (index 0 = front-most).
    static func frontToBackWindowIDs() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let number = info[kCGWindowNumber as String] as? NSNumber {
                order[CGWindowID(number.uint32Value)] = index
            }
        }
        return order
    }
}
