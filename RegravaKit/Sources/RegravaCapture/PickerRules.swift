import CoreGraphics

/// Geometry rules of the record picker and the recording bounds indicator.
public enum PickerRules {
    /// Whether two rectangles overlap enough: one inside the other, or their intersection
    /// covering at least `ratio` of the smaller one.
    public static func overlaps(_ a: CGRect, _ b: CGRect, ratio: Double = 0.5) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let shared = Double(intersection.width * intersection.height)
        let smaller = min(Double(a.width * a.height), Double(b.width * b.height))
        if smaller == shared { return true }
        return shared / smaller >= ratio
    }

    /// The share of a display the recorded bounds must cover for the display to show them.
    public static let boundsIndicatorOverlap = 0.7

    /// Whether a rectangle lies entirely inside the bounds.
    public static func isInside(_ rect: CGRect, _ bounds: CGRect) -> Bool {
        rect.minX >= bounds.minX && rect.minY >= bounds.minY && rect.maxX <= bounds.maxX && rect.maxY <= bounds.maxY
    }

    /// An area moved or resized with the arrow keys, or nil when the change would leave the
    /// display or give a negative size (the area then stays where it is).
    public static func arrowChange(_ rect: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, display: CGSize) -> CGRect? {
        // Plain numbers: a CGRect would hide a negative size.
        let x = resize ? rect.minX : rect.minX + dx
        let y = resize ? rect.minY : rect.minY + dy
        let width = resize ? rect.width + dx : rect.width
        let height = resize ? rect.height + dy : rect.height
        let inside = x >= 0 && y >= 0 && x + width <= display.width && y + height <= display.height
        guard inside, width >= 0, height >= 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A window is offered to be ignored when it has exactly the display's size.
    public static func isFullscreen(window: CGRect, display: CGRect) -> Bool {
        window.width == display.width && window.height == display.height
    }
}

/// A width × height in points.
public struct PickerSize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// "W × H".
    public var label: String { "\(width) × \(height)" }

    /// Whether the size fits in a display of the given size.
    public func fits(_ display: CGSize) -> Bool {
        CGFloat(width) <= display.width && CGFloat(height) <= display.height
    }
}

/// Sizes the window picker's "Resize" menu offers.
public enum WindowSizePresets {
    public static let sixteenByNine = sizes([(1280, 720), (1920, 1080), (2560, 1440)])
    public static let fourByThree = sizes([(640, 480), (800, 600), (1024, 768), (1280, 960), (1600, 1200)])
    public static let square = sizes([(640, 640), (800, 800), (1024, 1024), (1280, 1280), (1600, 1600)])
    public static let nineBySixteen = sizes([(720, 1280), (900, 1600), (1080, 1920), (1440, 2560)])
    public static let sixteenByTen = sizes([(640, 400), (800, 500), (1024, 640), (1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600)])

    /// Every built-in size; a size among them is never offered to be saved.
    public static let all = sixteenByNine + fourByThree + nineBySixteen + sixteenByTen + square

    /// A size can be picked when it fits the display and is not the current size.
    public static func isEnabled(_ size: PickerSize, current: PickerSize, display: CGSize) -> Bool {
        size.fits(display) && size != current
    }

    /// "Save current size" is hidden when the size is built in or already saved.
    public static func canSave(_ current: PickerSize, saved: [PickerSize]) -> Bool {
        !(all + saved).contains(current)
    }

    private static func sizes(_ list: [(Int, Int)]) -> [PickerSize] {
        list.map { PickerSize(width: $0.0, height: $0.1) }
    }
}
