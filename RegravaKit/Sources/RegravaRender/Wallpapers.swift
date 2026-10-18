import AppKit
import Foundation
import RegravaCore

/// The wallpaper library: images by Apple (macOS), Black Pixel Studio and Raycast, bundled
/// under `Wallpapers/<Category>/`.
public enum WallpaperLibrary {
    public struct Wallpaper: Hashable, Sendable, Identifiable {
        /// "Category/file.jpg", stored as the background's `systemName`.
        public let id: String
        public let name: String
    }

    public struct Category: Hashable, Sendable, Identifiable {
        public let name: String
        public let wallpapers: [Wallpaper]
        public var id: String { name }
        /// "Those beautiful images were created by <author>".
        public var author: (name: String, url: URL)? {
            switch name {
            case "Raycast": return ("Raycast", URL(string: "https://raycast.com")!)
            case "Energy", "Spring", "Sunset", "Radiant", "Midnight", "Iridescent":
                return ("Black Pixel Studio", URL(string: "https://bpxl.lemonsqueezy.com/")!)
            default: return nil
            }
        }
    }

    /// Category order.
    static let categoryOrder = ["macOS", "Spring", "Sunset", "Radiant", "Energy", "Iridescent", "Midnight", "Glassmorphism", "Raycast"]

    /// Wallpaper order inside categories that have one.
    static let wallpaperOrder: [String: [String]] = [
        "macOS": ["San Francisco Dark", "San Francisco Light", "Tahoe Light", "Tahoe Dark", "Sequoia Blue Orange", "Sequoia Blue", "Sonoma Dark", "Sonoma Light", "Sonoma Horizon", "Sonoma Evening", "Sonoma From Above", "Sonoma Clouds", "Sonoma River", "iPad 17 Dark", "iPad 17 Light", "Ventura Dark", "Ventura Semi Dark", "Ventura"],
        "Raycast": "Blob Red.Blob.Blue Distortion 1.Blue Distortion 2.Chromatic Dark 1.Chromatic Dark 2.Chromatic Light 1.Chromatic Light 2.Cube Mono.Cube Prod.Loupe Mono Dark.Loupe Mono Light.Loupe.Mono Dark Distortion 1.Mono Dark Distortion 2.Mono Light Distortion 1.Mono Light Distortion 2.Red Distortion 1.Red Distortion 2.Red Distortion 3.Red Distortion 4.Autumnal Peach.Blossom.Blushing Fire.Bright Rain.Floss.Glass Rainbow.Good Vibes.Moonrise.Ray Of Lights.Rose Thorn".components(separatedBy: "."),
    ]

    /// Older ids.
    static let legacyIDs: [String: String] = [
        "ventura": "macOS/ventura.jpg", "ventura-semi-dark": "macOS/ventura-semi-dark.jpg", "ventura-dark": "macOS/ventura-dark.jpg",
        "sonoma-clouds": "macOS/sonoma-clouds.jpg", "sonoma-dark": "macOS/sonoma-dark.jpg", "sonoma-evening": "macOS/sonoma-evening.jpg",
        "sonoma-from": "macOS/sonoma-from-above.jpg", "sonoma-horizon": "macOS/sonoma-horizon.jpg", "sonoma-light": "macOS/sonoma-light.jpg",
        "ipad-17-light": "macOS/ipad-17-light.jpg", "ipad-17-dark": "macOS/ipad-17-dark.jpg",
        "autumnal-peach": "Raycast/autumnal-peach.jpg", "blushing-fire": "Raycast/blushing-fire.jpg", "floss": "Raycast/floss.jpg",
        "good-vibes": "Raycast/good-vibes.jpg", "ray-of-lights": "Raycast/ray-of-lights.jpg", "blossom": "Raycast/blossom.jpg",
        "bright-rain": "Raycast/bright-rain.jpg", "glass-rainbow": "Raycast/glass-rainbow.jpg", "moonrise": "Raycast/moonrise.jpg",
        "rose-thorn": "Raycast/rose-thorn.jpg",
    ]

    static var root: URL? { Bundle.module.url(forResource: "Wallpapers", withExtension: nil) }

    /// "ipad-17-dark.jpg" → "iPad 17 Dark".
    static func displayName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
            .split(separator: "-")
            .map { $0 == "ipad" ? "iPad" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public static let categories: [Category] = {
        guard let root else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let ordered = names.sorted { (categoryOrder.firstIndex(of: $0) ?? .max, $0) < (categoryOrder.firstIndex(of: $1) ?? .max, $1) }
        return ordered.compactMap { category in
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(category).path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".jpg") }
            guard !files.isEmpty else { return nil }
            var wallpapers = files.map { Wallpaper(id: "\(category)/\($0)", name: displayName($0)) }
            let order = wallpaperOrder[category] ?? []
            wallpapers.sort { a, b in
                let ia = order.firstIndex(of: a.name) ?? .max, ib = order.firstIndex(of: b.name) ?? .max
                return ia != ib ? ia < ib : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return Category(name: category, wallpapers: wallpapers)
        }
    }()

    /// File for a wallpaper id.
    public static func url(for id: String) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(legacyIDs[id] ?? id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func category(containing id: String) -> Category? {
        categories.first { $0.wallpapers.contains { $0.id == id } }
    }
}
