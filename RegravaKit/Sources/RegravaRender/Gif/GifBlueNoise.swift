import Foundation

/// A 64x64 tileable blue-noise threshold map (void-and-cluster, Gaussian kernel of variance 2.25,
/// 409 seed points drawn with SplitMix64 from seed 0x5EED). Thresholds are (rank + 0.5) / 4096.
enum GifBlueNoise {
    static let size = 64

    /// Thresholds, row-major: `thresholds[(y & 63) * 64 + (x & 63)]`.
    nonisolated(unsafe) static let thresholds: UnsafeMutablePointer<Float> = generate()

    static func generate() -> UnsafeMutablePointer<Float> {
        let n = size * size
        // Energy a point adds at an offset (dx, dy), with offsets wrapping around the tile.
        var kernel = [Float](repeating: 0, count: n)
        for dy in 0..<size {
            let ddy = min(size - dy, dy)
            for dx in 0..<size {
                let ddx = min(size - dx, dx)
                kernel[dy * size + dx] = exp(Float(ddx * ddx + ddy * ddy) / -4.5)
            }
        }

        func spread(_ energy: inout [Float], at index: Int, adding: Bool) {
            let px = index & 63, py = index >> 6
            for y in 0..<size {
                let row = ((y - py + 64) & 63) * size
                for x in 0..<size {
                    let k = kernel[row + ((x - px + 64) & 63)]
                    if adding {
                        energy[y * size + x] = k + energy[y * size + x]
                    } else {
                        energy[y * size + x] = energy[y * size + x] - k
                    }
                }
            }
        }

        // Tightest cluster: the set point with the highest energy (first one on ties).
        func tightestCluster(_ bits: [Bool], _ energy: [Float]) -> Int {
            var best = -1
            for i in 0..<n where bits[i] {
                if best < 0 || energy[best] < energy[i] { best = i }
            }
            return best
        }

        // Largest void: the empty point with the lowest energy (first one on ties).
        func largestVoid(_ bits: [Bool], _ energy: [Float]) -> Int {
            var best = -1
            for i in 0..<n where !bits[i] {
                if best < 0 || energy[i] < energy[best] { best = i }
            }
            return best
        }

        var bits = [Bool](repeating: false, count: n)
        var energy = [Float](repeating: 0, count: n)
        let initialCount = 409
        var state: UInt64 = 0x5EED
        var placed = 0
        while placed < initialCount {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let index = Int(z & 0xFFF)
            if bits[index] { continue }
            bits[index] = true
            spread(&energy, at: index, adding: true)
            placed += 1
        }

        // Move points from the tightest cluster to the largest void until that is a no-op.
        while true {
            let cluster = tightestCluster(bits, energy)
            bits[cluster] = false
            spread(&energy, at: cluster, adding: false)
            let void = largestVoid(bits, energy)
            if void == cluster {
                bits[cluster] = true
                spread(&energy, at: cluster, adding: true)
                break
            }
            bits[void] = true
            spread(&energy, at: void, adding: true)
        }

        var ranks = [Int](repeating: 0, count: n)
        // Ranks below the seed count: remove clusters from a copy of the prototype.
        var prototypeBits = bits
        var prototypeEnergy = energy
        var rank = initialCount
        repeat {
            let cluster = tightestCluster(prototypeBits, prototypeEnergy)
            prototypeBits[cluster] = false
            spread(&prototypeEnergy, at: cluster, adding: false)
            rank -= 1
            ranks[cluster] = rank
        } while rank > 0
        // Ranks above: fill voids of the prototype one by one.
        rank = initialCount
        while rank != n {
            let void = largestVoid(bits, energy)
            bits[void] = true
            spread(&energy, at: void, adding: true)
            ranks[void] = rank
            rank += 1
        }

        let thresholds = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let scale = Float(bitPattern: 0x3980_0000)
        for i in 0..<n {
            thresholds[i] = (Float(ranks[i]) + 0.5) * scale
        }
        return thresholds
    }
}
