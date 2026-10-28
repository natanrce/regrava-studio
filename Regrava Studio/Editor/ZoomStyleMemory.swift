import Foundation
import RegravaCore

/// "Last edited zoom style" (`projectPreferences-lastEditedStyle-zoom`): saved after every zoom edit,
/// applied to zooms added at the playhead (not to zooms drawn on the track).
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

    static func capture(_ zoom: ZoomRange) {
        let style = LastEditedZoomStyle(zoom: zoom.scale, presentation: zoom.presentation, loupeOptions: zoom.loupeOptions, hasInstantAnimation: zoom.isInstant)
        guard style != stored, let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: key)
        cached = .some(style)
    }
}
