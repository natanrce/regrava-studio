import CoreImage
import Foundation

/// Splits a frame into Core Image passes that cannot read past what an input drew.
///
/// Core Image joins a graph into as few GPU programs as it can. An input it cannot join (a
/// kernel's output, or a part split off once a program needs more than the 15 textures the
/// GPU binds) is drawn into a texture with a one-pixel ring around its extent, and the program
/// reading it clamps every read past the texture to that ring. Core Image takes the ring as
/// clear, but a layer that draws past its extent (an antialiased edge, a trail kernel) leaves
/// colour there, and the clamped reads smear it over everything around: vertical streaks
/// along the top of the background, a band down its left side.
///
/// So every layer is cleared outside its extent where it is read, and stages that gather many
/// layers end their pass well before the texture limit.
///
/// Every pass's output is kept under the hash of what it was drawn from: its kernels, their
/// parameters, the region drawn and the hashes of its inputs, so a change anywhere below a pass
/// changes its hash too. A frame whose pass hashes the same is served the kept output instead of
/// drawing it again. A video frame hashes by its buffer and what the buffer holds: a playing
/// frame draws the passes reading it anew, a frame drawn again from the same buffer (a paused
/// redraw) is served them, and passes that read no video (the background, captions,
/// shortcuts) are drawn once while they stay the same. Kept outputs are released once no frame
/// has been drawn for `KeepAlive.idleRelease` seconds.
enum RenderPass {
    /// Textures one program of the frame may read; 3 below the limit, for the reads Core
    /// Image adds itself.
    static let maxTextures = 12

    /// Textures `stack` counts for each layer.
    static let texturesPerLayer = 2

    /// Textures the screen, cursor and camera over the background read, at most, in the pass
    /// that draws the frame.
    static let sessionTextures = 7

    /// `image` drawn in a pass of its own, read as one texture by the passes after it. The
    /// pass draws `rasterScale` times larger and is scaled back, for an image drawn at that
    /// scale afterwards: its pixels stay the output's.
    static func ended(_ image: CIImage, rasterScale: CGSize = CGSize(width: 1, height: 1)) -> CIImage {
        guard !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        let scale = CGAffineTransform(scaleX: rasterScale.width, y: rasterScale.height)
        guard rasterScale != CGSize(width: 1, height: 1) else { return served(clipped(image)) }
        return served(clipped(image.transformed(by: scale))).transformed(by: scale.inverted())
    }

    /// `image` drawn in a pass whose output is kept under its hash, served to a later frame
    /// drawing the same.
    static func served(_ image: CIImage) -> CIImage {
        guard !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        return image.insertingIntermediate(cache: true)
    }

    /// Releases the outputs kept for frames once none has been drawn for a while.
    static let keepAlive = KeepAlive { CanvasCompositor.context.clearCaches() }

    /// Calls `release` once nothing was used for `idleRelease` seconds: every `sweepInterval`
    /// while something is held, it checks the time since the last use.
    final class KeepAlive: @unchecked Sendable {
        static let idleRelease: TimeInterval = 5
        static let sweepInterval: TimeInterval = 1

        private let lock = NSLock()
        private let release: @Sendable () -> Void
        private let now: @Sendable () -> TimeInterval
        private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
        private var lastUsed: TimeInterval?
        private var isSweepScheduled = false

        init(
            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
            },
            release: @escaping @Sendable () -> Void
        ) {
            self.now = now
            self.schedule = schedule
            self.release = release
        }

        /// Something was drawn now.
        func markUsed() {
            lock.lock()
            lastUsed = now()
            let needsSweep = !isSweepScheduled
            isSweepScheduled = true
            lock.unlock()
            if needsSweep { scheduleSweep() }
        }

        /// Whether outputs are held: used since the last release.
        var isHolding: Bool {
            lock.lock()
            defer { lock.unlock() }
            return lastUsed != nil
        }

        private func scheduleSweep() {
            schedule(Self.sweepInterval) { [weak self] in self?.sweep() }
        }

        private func sweep() {
            lock.lock()
            guard let lastUsed else {
                isSweepScheduled = false
                lock.unlock()
                return
            }
            if now() - lastUsed > Self.idleRelease {
                self.lastUsed = nil
                isSweepScheduled = false
                lock.unlock()
                release()
                return
            }
            lock.unlock()
            scheduleSweep()
        }
    }

    /// How far past its extent a layer may draw: antialiased edges spill about a pixel.
    static let fringe = 2.0

    /// `image` cleared past its extent and `fringe` in the program that reads it. A plain crop
    /// to the extent is dropped by Core Image as a no-op.
    static func clipped(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        // Core Image drops a mask wider than the image it masks, so the image is first grown
        // to the mask with clear.
        let kept = extent.insetBy(dx: -fringe, dy: -fringe).integral
        return image.composited(over: CIImage(color: .clear).cropped(to: kept))
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: kept)])
    }

    /// `layers` drawn over `base`, bottom first, each cleared outside its extent. Past
    /// `maxTextures`, runs of layers are drawn over clear inside their own bounds in passes
    /// of their own and those runs composited instead, as many times as it takes, so the pass
    /// over `base` reads at most `maxTextures` (`base` counts `baseTextures`).
    static func stack(_ layers: [CIImage], over base: CIImage, baseTextures: Int = 1, rasterScale: CGSize = CGSize(width: 1, height: 1)) -> CIImage {
        let layers = layers.filter { !$0.extent.isEmpty }.map(clipped)
        return stack(layers, over: base, baseTextures: baseTextures, texturesPerLayer: texturesPerLayer, rasterScale: rasterScale)
    }

    private static func stack(_ layers: [CIImage], over base: CIImage, baseTextures: Int, texturesPerLayer: Int, rasterScale: CGSize) -> CIImage {
        guard layers.count > max(1, (maxTextures - baseTextures) / texturesPerLayer) else {
            return layers.reduce(base) { $1.composited(over: $0) }
        }
        let runLength = max(1, maxTextures / texturesPerLayer)
        let runs = stride(from: 0, to: layers.count, by: runLength).map { start -> CIImage in
            let run = layers[start..<min(start + runLength, layers.count)]
            let bounds = run.reduce(CGRect.null) { $0.union($1.extent) }
            return ended(run.reduce(CIImage(color: .clear).cropped(to: bounds)) { $1.composited(over: $0) }, rasterScale: rasterScale)
        }
        // A run reads as one texture.
        return stack(runs, over: base, baseTextures: baseTextures, texturesPerLayer: 1, rasterScale: rasterScale)
    }
}
