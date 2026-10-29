import AppKit
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
                processID: app.processID
            )
        }
        return windows.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
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
