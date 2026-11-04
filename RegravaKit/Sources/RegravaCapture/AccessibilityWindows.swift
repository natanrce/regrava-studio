import AppKit
import ApplicationServices
import CoreGraphics

/// A window seen through the Accessibility API: its corner radius, and bringing it to the
/// front or resizing it.
public struct AccessibilityWindow {
    public let element: AXUIElement
    public let application: AXUIElement

    /// How well an Accessibility window matches a listed window: 3 for the same title, 2 when
    /// its title contains the listed one, plus 1 for the same position (within 5 pt) or 2 for
    /// the same position and size.
    static func matchScore(axTitle: String?, axFrame: CGRect?, title: String, frame: CGRect) -> Int {
        var score = 0
        if let axTitle {
            if axTitle == title {
                score = 3
            } else if !title.isEmpty, axTitle.contains(title) {
                score = 2
            }
        }
        guard let axFrame,
              abs(axFrame.minX - frame.minX) < 5, abs(axFrame.minY - frame.minY) < 5 else { return score }
        if abs(axFrame.width - frame.width) < 5, abs(axFrame.height - frame.height) < 5 { return score + 2 }
        return score + 1
    }

    /// The app's window that best matches the listed one, if any scores above zero.
    public static func matching(processID: pid_t, title: String, frame: CGRect) -> AccessibilityWindow? {
        let application = AXUIElementCreateApplication(processID)
        guard let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute), !windows.isEmpty else { return nil }
        var best: (window: AXUIElement, score: Int)?
        for window in windows {
            let axTitle: String? = attribute(window, kAXTitleAttribute)
            var axFrame: CGRect?
            if let origin = pointValue(window, kAXPositionAttribute), let size = sizeValue(window, kAXSizeAttribute) {
                axFrame = CGRect(origin: origin, size: size)
            }
            let score = matchScore(axTitle: axTitle, axFrame: axFrame, title: title, frame: frame)
            guard score > 0 else { continue }
            if best == nil || best!.score < score { best = (window, score) }
        }
        return best.map { AccessibilityWindow(element: $0.window, application: application) }
    }

    /// Corner radius of a window: 16 for dialogs and sheets, 0 in full screen, 20 or 26 with a
    /// toolbar (20 when it is at most 50 pt tall), else 16.
    public var cornerRadius: Double {
        let subrole: String? = Self.attribute(element, kAXSubroleAttribute)
        let children: [AXUIElement]? = Self.attribute(element, kAXChildrenAttribute)
        return Self.cornerRadius(subrole: subrole, childRoles: (children ?? []).lazy.map { child in
            (role: Self.attribute(child, kAXRoleAttribute) as String?, height: { Self.sizeValue(child, kAXSizeAttribute)?.height })
        })
    }

    static func cornerRadius<Children: Sequence>(subrole: String?, childRoles: Children) -> Double
    where Children.Element == (role: String?, height: () -> CGFloat?) {
        switch subrole {
        case "AXDialog", "AXSheet": return 16
        case "AXFullScreen": return 0
        default: break
        }
        for child in childRoles where child.role == "AXToolbar" {
            guard let height = child.height() else { return 26 }
            return height <= 50 ? 20 : 26
        }
        return 16
    }

    /// Makes the app frontmost, raises the window and makes it main and focused.
    public func raise() {
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Sets the window's size; false when the app refused it.
    @discardableResult
    public func resize(to size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func pointValue(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = axValue(element, name) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = axValue(element, name) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}

/// Window actions of the picker.
public enum WindowActions {
    /// Activates the window's app and raises the window.
    @MainActor
    public static func bringToFront(_ window: WindowInfo) {
        let ax = AccessibilityWindow.matching(processID: window.processID, title: window.title, frame: window.frame)
        if let app = NSRunningApplication(processIdentifier: window.processID) {
            if #available(macOS 14, *) {
                app.activate(options: [])
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        ax?.raise()
    }

    /// Resizes the window; false when it could not be resized.
    @discardableResult
    public static func resize(_ window: WindowInfo, to size: CGSize) -> Bool {
        guard let ax = AccessibilityWindow.matching(processID: window.processID, title: window.title, frame: window.frame) else { return false }
        return ax.resize(to: size)
    }
}
