import Foundation

/// A colour in OkLab (`x` = L, `y` = a, `z` = b) or in linear sRGB (`x` = r, `y` = g, `z` = b).
struct GifColor: Equatable {
    var x: Float
    var y: Float
    var z: Float

    static let zero = GifColor(x: 0, y: 0, z: 0)

    /// Squared distance, summed as (x + y) + z.
    @inline(__always)
    func distanceSquared(to other: GifColor) -> Float {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return dx * dx + dy * dy + dz * dz
    }
}

/// sRGB <-> linear <-> OkLab conversions shared by the GIF encoder. Every constant is the exact
/// single-precision value the encoder uses.
enum GifColorMath {
    // Linear sRGB -> LMS.
    static let m00 = Float(bitPattern: 0x3ED3_0EB1), m01 = Float(bitPattern: 0x3F09_4D17), m02 = Float(bitPattern: 0x3D52_B909)
    static let m10 = Float(bitPattern: 0x3E58_FD3B), m11 = Float(bitPattern: 0x3F2E_4253), m12 = Float(bitPattern: 0x3DDB_F2F0)
    static let m20 = Float(bitPattern: 0x3DB4_D7EC), m21 = Float(bitPattern: 0x3E90_3D74), m22 = Float(bitPattern: 0x3F21_4649)
    // Cube-rooted LMS -> OkLab.
    static let lL = Float(bitPattern: 0x3E57_8152), lM = Float(bitPattern: 0x3F4B_2A89), lS = Float(bitPattern: 0x3B85_6ECE)
    static let aL = Float(bitPattern: 0x3FFD_2F0E), aM = Float(bitPattern: 0x401B_6E0E), aS = Float(bitPattern: 0x3EE6_B438)
    static let bL = Float(bitPattern: 0x3CD4_34B4), bM = Float(bitPattern: 0x3F48_63BB), bS = Float(bitPattern: 0x3F4F_0560)
    // OkLab -> cube-rooted LMS.
    static let ia1 = Float(bitPattern: 0x3ECA_ECC9), ib1 = Float(bitPattern: 0x3E5C_FBA9)
    static let ia2 = Float(bitPattern: 0xBDD8_308C), ib2 = Float(bitPattern: 0xBD82_C5FA)
    static let ia3 = Float(bitPattern: 0xBDB7_437B), ib3 = Float(bitPattern: 0xBFA5_4F66)
    // LMS -> linear sRGB.
    static let rL = Float(bitPattern: 0x4082_74AB), rM = Float(bitPattern: 0x4053_B18C), rS = Float(bitPattern: 0x3E6C_8362)
    static let gL = Float(bitPattern: 0x3FA2_5C2D), gM = Float(bitPattern: 0x4027_0644), gS = Float(bitPattern: 0x3EAE_C16A)
    static let xL = Float(bitPattern: 0xBB89_7F53), xM = Float(bitPattern: 0x3F34_133E), xS = Float(bitPattern: 0x3FDA_931E)

    /// Linear value of every 8-bit sRGB code.
    nonisolated(unsafe) static let srgbToLinear: UnsafeMutablePointer<Float> = {
        let table = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        for i in 0..<256 {
            table[i] = decode(Float(i) / 255)
        }
        return table
    }()

    /// sRGB byte for 4096 evenly spaced linear values in 0...1.
    nonisolated(unsafe) static let linearToSrgbTable: UnsafeMutablePointer<UInt8> = {
        let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        for i in 0..<4096 {
            let v = Float(i) / 4095
            let encoded = v <= 0.0031308 ? v * 12.92 : pow(v, Float(bitPattern: 0x3ED5_5555)) * 1.055 + -0.055
            let rounded = (encoded * 255).rounded()
            let clamped = rounded < 0 ? 0 : (255 <= rounded ? 255 : rounded)
            table[i] = UInt8(clamped)
        }
        return table
    }()

    /// sRGB transfer function, 0...1 -> linear.
    @inline(__always)
    static func decode(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linearToSrgbByte(_ value: Float) -> UInt8 {
        let clamped = value < 0 ? 0 : value
        let position = 1 <= value ? Float(4095.5) : clamped * 4095 + 0.5
        return linearToSrgbTable[Int(position)]
    }

    @inline(__always)
    static func linear(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> GifColor {
        GifColor(x: srgbToLinear[Int(r)], y: srgbToLinear[Int(g)], z: srgbToLinear[Int(b)])
    }

    @inline(__always)
    static func oklab(linear c: GifColor) -> GifColor {
        let l = cbrt(m00 * c.x + m01 * c.y + m02 * c.z)
        let m = cbrt(m10 * c.x + m11 * c.y + m12 * c.z)
        let s = cbrt(m20 * c.x + m21 * c.y + m22 * c.z)
        return GifColor(
            x: lL * l + lM * m - lS * s,
            y: aL * l - aM * m + aS * s,
            z: bL * l + bM * m - bS * s
        )
    }

    @inline(__always)
    static func oklab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> GifColor {
        oklab(linear: linear(r, g, b))
    }

    @inline(__always)
    static func linear(oklab c: GifColor) -> GifColor {
        let l1 = c.x + ia1 * c.y + ib1 * c.z
        let m1 = c.x + ia2 * c.y + ib2 * c.z
        let s1 = c.x + ia3 * c.y + ib3 * c.z
        let l = l1 * l1 * l1, m = m1 * m1 * m1, s = s1 * s1 * s1
        return GifColor(
            x: rL * l - rM * m + rS * s,
            y: gM * m - gL * l - gS * s,
            z: xL * l - xM * m + xS * s
        )
    }
}
