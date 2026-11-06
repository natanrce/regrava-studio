import Foundation
import RegravaCore

/// Rendered blocks of the mix for reading it at any position and in either direction.
final class MixBlockCache {
    static let blockFrames = 65_536
    /// Blocks kept, most recently used last.
    static let capacity = 16

    let renderer: MixRenderer
    private var blocks: [Int: (left: [Float], right: [Float])] = [:]
    private var recent: [Int] = []

    init(renderer: MixRenderer) {
        self.renderer = renderer
    }

    func block(_ index: Int) -> (left: [Float], right: [Float]) {
        if let cached = blocks[index] {
            if recent.last != index {
                recent.removeAll { $0 == index }
                recent.append(index)
            }
            return cached
        }
        let start = Int64(index) * Int64(Self.blockFrames)
        if renderer.position != start { renderer.seek(to: start) }
        var left = [Float](repeating: 0, count: Self.blockFrames), right = [Float](repeating: 0, count: Self.blockFrames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(left: l.baseAddress!, right: r.baseAddress!, count: Self.blockFrames)
            }
        }
        blocks[index] = (left, right)
        recent.append(index)
        if recent.count > Self.capacity {
            let oldest = recent.removeFirst()
            blocks[oldest] = nil
        }
        return (left, right)
    }

    /// Renders one missing block around a head: its own, then the next, the previous and the
    /// one after next in its direction.
    func prefetch(for head: MixHead) {
        for blocksAhead in [0.0, 1.0, -1.0, 2.0] {
            let frame = Int64((head.position + head.direction * blocksAhead * Double(Self.blockFrames)).rounded(.down))
            guard frame >= 0, frame < renderer.layout.frameCount else { continue }
            let index = Int(frame >> 16)
            if blocks[index] == nil {
                _ = block(index)
                return
            }
        }
    }
}

/// Reads the cached mix frame by frame from a position, forward or backward, into a stretcher
/// that sets its speed.
final class MixHead {
    /// +1 or −1.
    let direction: Double
    /// The next frame to read.
    var position: Double
    var speed: Double
    var stretcher: TimeStretcher?

    init(at position: Double, direction: Double, speed: Double, cache: MixBlockCache) throws {
        self.direction = direction
        self.position = position
        self.speed = speed
        let stretcher = try TimeStretcher(speed: 1, algorithm: .current) { [unowned self, unowned cache] left, right, count in
            for i in 0..<count {
                let frame = Int64(self.position.rounded(.down))
                if frame >= 0, frame < cache.renderer.layout.frameCount {
                    let block = cache.block(Int(frame >> 16))
                    let offset = Int(frame & 0xFFFF)
                    left[i] = block.left[offset]
                    right[i] = block.right[offset]
                } else {
                    left[i] = 0
                    right[i] = 0
                }
                self.position += self.direction
            }
        }
        self.stretcher = stretcher
    }

    /// Frames a fresh head is primed with: the stretcher's latency plus 2048.
    static let primingExtraFrames = 2048
}
