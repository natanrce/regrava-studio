import Foundation
import RegravaCore

/// "Last edited zoom style" (`projectPreferences-lastEditedStyle-zoom`): saved after an edit that
/// changes a zoom's style, applied to zooms added at the playhead (not to zooms drawn on the track).
struct LastEditedZoomStyle: Codable, Equatable {
    var zoom: Double
    var presentation: ZoomPresentation
    var loupeOptions: LoupeOptions
    var hasInstantAnimation: Bool

    private static let key = "projectPreferences-lastEditedStyle-zoom"

    /// Decoded once, then kept in step by `capture` (read on every pointer move over the zoom
    /// track); any other defaults change, a reset included, decodes it again.
    private static var cached: LastEditedZoomStyle?? = nil
    private static var defaultsObserver: NSObjectProtocol?

    static var stored: LastEditedZoomStyle? {
        if let cached { return cached }
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cached = nil }
            }
        }
        let style = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastEditedZoomStyle.self, from: $0) }
        cached = .some(style)
        return style
    }

    init(_ zoom: ZoomRange) {
        self.init(zoom: zoom.scale, presentation: zoom.presentation, loupeOptions: zoom.loupeOptions, hasInstantAnimation: zoom.isInstant)
    }

    init(zoom: Double, presentation: ZoomPresentation, loupeOptions: LoupeOptions, hasInstantAnimation: Bool) {
        self.zoom = zoom
        self.presentation = presentation
        self.loupeOptions = loupeOptions
        self.hasInstantAnimation = hasInstantAnimation
    }

    /// `captureStyleIfEdited`: only an update that changed the zoom's style is remembered.
    static func capture(_ zoom: ZoomRange, ifChangedFrom before: ZoomRange) {
        guard LastEditedZoomStyle(before) != LastEditedZoomStyle(zoom) else { return }
        capture(zoom)
    }

    static func capture(_ zoom: ZoomRange) {
        let style = LastEditedZoomStyle(zoom)
        guard style != stored, let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: key)
        cached = .some(style)
    }
}

/// "Last edited mask style" (`projectPreferences-lastEditedStyle-mask`): the blur and highlight
/// opacity of the last mask edit that changed them, applied to masks added at the playhead.
struct LastEditedMaskStyle: Codable, Equatable {
    var blur: Double
    var highlightMaskOpacity: Double

    private static let key = "projectPreferences-lastEditedStyle-mask"

    init(_ mask: MaskRange) {
        blur = mask.blur
        highlightMaskOpacity = mask.highlightMaskOpacity
    }

    static var stored: LastEditedMaskStyle? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastEditedMaskStyle.self, from: $0) }
    }

    static func capture(_ mask: MaskRange, ifChangedFrom before: MaskRange) {
        let style = LastEditedMaskStyle(mask)
        guard LastEditedMaskStyle(before) != style, let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
