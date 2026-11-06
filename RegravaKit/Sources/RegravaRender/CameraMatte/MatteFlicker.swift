import Foundation

/// Steadies a matte over time: a pixel takes the median of its neighbours in time (five frames
/// when two on each side exist, else three) where the footage barely changes around it, and
/// keeps its own value where the footage moved.
enum MatteFlicker {
    /// Squared colour change (summed over r, g and b, 0…255 each) below which a pixel counts as still.
    static let stillColorDistanceSquared = 417

    /// `guides` are the footage at matte size, three planes (r, g, b) one after another. Without
    /// the frame before and after (and their guides) the matte stays as it is.
    static func filter(
        mattes: (before2: [UInt8]?, before: [UInt8]?, own: [UInt8], after: [UInt8]?, after2: [UInt8]?),
        guides: (before: [UInt8]?, own: [UInt8], after: [UInt8]?)
    ) -> [UInt8] {
        guard let before = mattes.before, let after = mattes.after,
              let guideBefore = guides.before, let guideAfter = guides.after else { return mattes.own }
        let own = mattes.own
        let count = own.count
        let guideOwn = guides.own
        var out = [UInt8](repeating: 0, count: count)
        let wide: (before2: [UInt8], after2: [UInt8])? = {
            guard let b2 = mattes.before2, let a2 = mattes.after2 else { return nil }
            return (b2, a2)
        }()
        for i in 0..<count {
            let o = own[i]
            let median: UInt8
            if let wide {
                let lo = max(min(o, after[i]), min(before[i], wide.before2[i]))
                let hi = min(max(o, after[i]), max(before[i], wide.before2[i]))
                let e = wide.after2[i]
                median = max(min(max(lo, e), hi), min(lo, e))
            } else {
                let b = before[i]
                median = max(min(max(b, o), after[i]), min(b, o))
            }
            var value = o
            if median != o {
                var toBefore = 0, toAfter = 0
                for plane in 0..<3 {
                    let index = plane * count + i
                    let own = Int(guideOwn[index])
                    let db = own - Int(guideBefore[index]), da = own - Int(guideAfter[index])
                    toBefore += db * db
                    toAfter += da * da
                }
                if max(toBefore, toAfter) < stillColorDistanceSquared { value = median }
            }
            out[i] = value
        }
        return out
    }
}

/// The filtered mattes of one chunk (`start..<end`), fed frame by frame in order. Frames just
/// outside the chunk give its edges their neighbours.
final class ChunkFlicker {
    let start: Int
    let end: Int
    let frameCount: Int
    private var inputs: [Int: (matte: [UInt8], guide: [UInt8])] = [:]
    private var outputs: [Int: [UInt8]] = [:]

    init(start: Int, end: Int, frameCount: Int) {
        self.start = start
        self.end = end
        self.frameCount = frameCount
    }

    /// A network matte and its guide. The frame two before it now has all its neighbours.
    func add(_ frame: Int, matte: [UInt8], guide: [UInt8]) {
        inputs[frame] = (matte, guide)
        filter(frame - 2)
        inputs = inputs.filter { $0.key >= frame - 4 }
    }

    func filter(_ frame: Int) {
        guard frame >= start, frame < end, outputs[frame] == nil, let own = inputs[frame] else { return }
        outputs[frame] = MatteFlicker.filter(
            mattes: (inputs[frame - 2]?.matte, inputs[frame - 1]?.matte, own.matte, inputs[frame + 1]?.matte, inputs[frame + 2]?.matte),
            guides: (inputs[frame - 1]?.guide, own.guide, inputs[frame + 1]?.guide)
        )
    }

    /// Every frame of the chunk, filtered with the neighbours it has; nil when one never came.
    func finish() -> [[UInt8]]? {
        for frame in start..<end where outputs[frame] == nil { filter(frame) }
        var mattes: [[UInt8]] = []
        for frame in start..<end {
            guard let matte = outputs[frame] else { return nil }
            mattes.append(matte)
        }
        return mattes
    }
}
