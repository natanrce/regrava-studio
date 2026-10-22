import AppKit
import CoreImage
import RegravaCore

/// One cursor image of a set: `sets/<set>/<type>-<n>__<hx>-<hy>.svg`.
public struct CursorSetEntry: Hashable, Sendable, Identifiable {
    /// "<type>-<n>".
    public let id: String
    public let type: String
    public let setID: String
    public let url: URL
    /// Hotspot in 0…1 of the full image (the file name's percentages).
    public let hotspot01: Vec2
}

public struct CursorSet: Sendable, Identifiable {
    public let id: String
    /// Entries per type, by variant number.
    public let cursors: [String: [CursorSetEntry]]

    /// The pointer list, else the pointing hand, else any.
    public var representativeEntries: [CursorSetEntry] {
        cursors["pointer"] ?? cursors["pointinghand"] ?? cursors.keys.sorted().compactMap { cursors[$0] }.first ?? []
    }

    /// Types with two or more variants, in a stable order.
    public var variantTypes: [String] {
        cursors.keys.filter { (cursors[$0]?.count ?? 0) >= 2 }.sorted { a, b in
            (a == "pointer" ? 0 : 1, a) < (b == "pointer" ? 0 : 1, b)
        }
    }

    /// The pointer, else the pointing hand, else the first entry.
    var fallback: CursorSetEntry? {
        cursors["pointer"]?.first ?? cursors["pointinghand"]?.first ?? cursors.keys.sorted().compactMap { cursors[$0]?.first }.first
    }

    /// `pick`: the type, else pointer, else pointing hand; the chosen variant, else the first.
    public func entry(forType requested: String, variants: [String: String]) -> CursorSetEntry? {
        var type = requested
        if cursors[type] == nil { type = "pointer" }
        if cursors[type] == nil { type = "pointinghand" }
        if let list = cursors[type] {
            return list.first { $0.id == variants[type] } ?? list.first ?? fallback
        }
        return fallback
    }
}

public enum CursorSets {
    /// The set order comes from the main process, which can't be read; this one starts
    /// with the default and the classic set (inferred).
    static let preferredOrder = ["macos-tahoe", "macos", "touch"] + (1...20).map { "custom-\($0)" } + ["halloween"]

    /// Every bundled set.
    public static let all: [CursorSet] = load()

    /// The sets the picker offers: Halloween only between 2025-10-20 and 2025-11-07.
    public static func pickable(now: Date = Date()) -> [CursorSet] {
        all.filter { set in
            guard set.id == "halloween" else { return true }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            guard let start = calendar.date(from: DateComponents(year: 2025, month: 10, day: 20)),
                  let end = calendar.date(from: DateComponents(year: 2025, month: 11, day: 7, hour: 23, minute: 59, second: 59)) else { return false }
            return now >= start && now <= end
        }
    }

    /// An unknown id falls back to the first set (`sets.find(...) ?? sets[0]`).
    public static func set(id: String) -> CursorSet? {
        all.first { $0.id == id } ?? all.first
    }

    private static func load() -> [CursorSet] {
        guard let root = Bundle.module.url(forResource: "CursorSets", withExtension: nil) else { return [] }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var sets: [CursorSet] = []
        for folder in folders where folder.hasDirectoryPath {
            let setID = folder.lastPathComponent
            var cursors: [String: [(n: Int, entry: CursorSetEntry)]] = [:]
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                guard let parsed = parse(file.lastPathComponent) else { continue }
                let entry = CursorSetEntry(id: "\(parsed.type)-\(parsed.n)", type: parsed.type, setID: setID, url: file, hotspot01: parsed.hotspot01)
                cursors[parsed.type, default: []].append((parsed.n, entry))
            }
            guard !cursors.isEmpty else { continue }
            sets.append(CursorSet(id: setID, cursors: cursors.mapValues { $0.sorted { $0.n < $1.n }.map(\.entry) }))
        }
        return sets.sorted { a, b in
            (preferredOrder.firstIndex(of: a.id) ?? Int.max, a.id) < (preferredOrder.firstIndex(of: b.id) ?? Int.max, b.id)
        }
    }

    /// "pointer-3__10-11.svg" (or ".svg.svg") → type, variant and hotspot in 0…1.
    static func parse(_ fileName: String) -> (type: String, n: Int, hotspot01: Vec2)? {
        var name = fileName
        while name.hasSuffix(".svg") { name.removeLast(4) }
        let halves = name.components(separatedBy: "__")
        guard halves.count == 2 else { return nil }
        let head = halves[0].split(separator: "-"), spot = halves[1].split(separator: "-")
        guard head.count == 2, let n = Int(head[1]), spot.count == 2, let hx = Double(spot[0]), let hy = Double(spot[1]) else { return nil }
        return (String(head[0]), n, Vec2(hx / 100, hy / 100))
    }
}

/// Bundled cursor art rasterised: SVGs drawn with the shorter edge at 512 px (`minEdgeSizePx`),
/// with their baked drop shadow (macOS's SVG renderer skips filters, so the Figma `feDropShadow`
/// chain is rebuilt from its parameters).
enum CursorRaster {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: CGImage] = [:]
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func image(_ url: URL, minEdge: Double = 512) -> CGImage? {
        lock.lock()
        if let cached = cache[url] { lock.unlock(); return cached }
        lock.unlock()
        guard let rendered = render(url, minEdge: minEdge) else { return nil }
        lock.lock()
        cache[url] = rendered
        lock.unlock()
        return rendered
    }

    struct DropShadow {
        var dx: Double, dy: Double, sigma: Double
        var color: (r: Double, g: Double, b: Double, a: Double)
    }

    /// The Figma drop shadows of an SVG: feOffset, feGaussianBlur and the final colour matrix.
    static func shadows(inSVG text: String) -> [DropShadow] {
        var out: [DropShadow] = []
        for filter in text.components(separatedBy: "<filter ").dropFirst() {
            let body = filter.components(separatedBy: "</filter>").first ?? filter
            guard let sigma = attribute("stdDeviation", in: body.slice(after: "<feGaussianBlur")).flatMap(Double.init) else { continue }
            let offset = body.slice(after: "<feOffset")
            let dx = attribute("dx", in: offset).flatMap(Double.init) ?? 0
            let dy = attribute("dy", in: offset).flatMap(Double.init) ?? 0
            // The last colour matrix: "0 0 0 0 R  0 0 0 0 G  0 0 0 0 B  0 0 0 A 0".
            let matrices = body.components(separatedBy: "<feColorMatrix").dropFirst().compactMap { attribute("values", in: $0) }
            let values = (matrices.last ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
            let color = values.count == 20 ? (values[4], values[9], values[14], values[18]) : (0.0, 0.0, 0.0, 0.25)
            out.append(DropShadow(dx: dx, dy: dy, sigma: sigma, color: color))
        }
        return out
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: " \(name)=\"") ?? text.range(of: "\n\(name)=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func render(_ url: URL, minEdge: Double) -> CGImage? {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else { return nil }
        let k = minEdge / min(svg.size.width, svg.size.height)
        let width = Int((svg.size.width * k).rounded()), height = Int((svg.size.height * k).rounded())
        guard let shape = draw(svg, width: width, height: height) else { return nil }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let shadows = shadows(inSVG: text)
        guard !shadows.isEmpty else { return shape }
        let base = CIImage(cgImage: shape)
        let extent = base.extent
        var result = CIImage.empty().cropped(to: extent)
        for s in shadows {
            let tinted = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.color.a)),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            // Premultiplied colour = alpha × rgb.
            let colored = tinted.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.color.r)),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.color.g)),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.color.b)),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let shadow = colored
                .clampedToExtent()
                .applyingGaussianBlur(sigma: s.sigma * k)
                .cropped(to: extent.insetBy(dx: -4 * s.sigma * k, dy: -4 * s.sigma * k))
                // SVG y points down, Core Image y up.
                .transformed(by: CGAffineTransform(translationX: s.dx * k, y: -s.dy * k))
                .cropped(to: extent)
            result = shadow.composited(over: result)
        }
        let composed = base.composited(over: result).cropped(to: extent)
        return context.createCGImage(composed, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Transparent edges stay transparent: blur from a padded transparent canvas.
    private static func draw(_ image: NSImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current?.flushGraphics()
        return context.makeImage()
    }

    /// The box of pixels at least as opaque as the mean of the non-clear ones, so the faint
    /// shadow and fringe are left out. 0…1, top-left origin.
    static func visibleRect01(_ image: CGImage) -> Rect2? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0, count = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] > 0 {
            sum += Int(pixels[i])
            count += 1
        }
        guard count > 0 else { return nil }
        let mean = Double(sum) / Double(count)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let a = Double(pixels[(y * width + x) * 4 + 3])
                if a > 0 && a >= mean {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's first row is the image's top.
        return Rect2(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                     width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
    }
}

private extension String {
    /// The text after the first `marker` up to the next ">".
    func slice(after marker: String) -> String {
        guard let range = range(of: marker) else { return "" }
        let rest = self[range.upperBound...]
        return String(rest[..<(rest.firstIndex(of: ">") ?? rest.endIndex)])
    }
}

public extension CursorSetEntry {
    /// The entry's image as drawn in previews and the picker (with its shadow).
    var image: CGImage? { CursorRaster.image(url) }
}
