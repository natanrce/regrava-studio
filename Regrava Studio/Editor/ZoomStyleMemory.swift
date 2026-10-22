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

    static var stored: LastEditedZoomStyle? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastEditedZoomStyle.self, from: $0) }
    }

    static func capture(_ zoom: ZoomRange) {
        let style = LastEditedZoomStyle(zoom: zoom.scale, presentation: zoom.presentation, loupeOptions: zoom.loupeOptions, hasInstantAnimation: zoom.isInstant)
        guard style != stored, let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
