import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import RegravaCore

/// Device frame images (`assets/devices/<key>.png`, the own art), loaded lazily and kept
/// as a few downsampled levels so they draw sharply at any size.
final class DeviceFrameArt: @unchecked Sendable {
    static let shared = DeviceFrameArt()

    private var levels: [String: [CIImage]] = [:]
    private let lock = NSLock()

    static func url(for key: String) -> URL? {
        Bundle.module.url(forResource: key, withExtension: "png", subdirectory: "Devices")
    }

    /// Full size, then halves down to about 256 px tall.
    private func mipLevels(_ key: String) -> [CIImage] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = levels[key] { return cached }
        guard let url = Self.url(for: key), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        var out = [CIImage(cgImage: full)]
        var current = full
        while current.height > 512, let half = Self.halved(current) {
            out.append(CIImage(cgImage: half))
            current = half
        }
        levels[key] = out
        return out
    }

    private static func halved(_ image: CGImage) -> CGImage? {
        let w = image.width / 2, h = image.height / 2
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// The frame stretched over `rect` (Core Image coordinates), stretching the image over the body.
    func image(for key: String, in rect: CGRect) -> CIImage? {
        let levels = mipLevels(key)
        guard !levels.isEmpty, rect.width > 0, rect.height > 0 else { return nil }
        // The smallest level still at least as large as the target.
        let level = levels.last { $0.extent.height >= rect.height } ?? levels[0]
        let sx = rect.width / level.extent.width, sy = rect.height / level.extent.height
        return level
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
