import Foundation
import MLX

/// Errors of the speech models. `SpeechModelError` is thrown when a result is not finite.
public enum SpeechModelError: Error, Equatable {
    case unavailable
    case unsupportedSampleRate(Double)
    case missingWeight(String)
    case badWeightShape(String, [Int])
    case notFinite
}

/// A safetensors file loaded with `MLX.loadArrays(url:)`, keyed exactly as on disk. Every
/// lookup is recorded so a test can prove that every tensor is consumed and none is missing.
final class Weights {
    private let arrays: [String: MLXArray]
    private(set) var used: Set<String> = []
    /// Weights are cast to this type at load (MossFormer2 is stored f16; TF-Restormer is stored f32
    /// and cast to f16).
    let dtype: DType

    init(url: URL, dtype: DType) throws {
        arrays = try loadArrays(url: url, stream: .cpu)
        self.dtype = dtype
    }

    var names: Set<String> { Set(arrays.keys) }
    var unused: Set<String> { names.subtracting(used) }

    /// The tensor `name`, checked against `shape`, cast to the model's dtype.
    func callAsFunction(_ name: String, _ shape: [Int]? = nil, dtype: DType? = nil) throws -> MLXArray {
        guard let array = arrays[name] else { throw SpeechModelError.missingWeight(name) }
        if let shape, array.shape != shape { throw SpeechModelError.badWeightShape(name, array.shape) }
        used.insert(name)
        let target = dtype ?? self.dtype
        return array.dtype == target ? array : array.asType(target)
    }
}

// MARK: - Shared layers

/// `x @ W (+ b)`: every Linear / 1x1 conv is stored `[in, out]` (MLX layout).
struct Linear {
    let weight: MLXArray
    let bias: MLXArray?

    init(_ w: Weights, _ prefix: String, _ inDim: Int, _ outDim: Int, bias: Bool = true) throws {
        weight = try w(prefix + ".weight", [inDim, outDim])
        self.bias = bias ? try w(prefix + ".bias", [outDim]) : nil
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if let bias { return addMM(bias, x, weight) }
        return matmul(x, weight)
    }
}

/// LayerNorm over the last axis.
struct LayerNorm {
    let weight: MLXArray
    let bias: MLXArray
    let eps: Float

    init(_ w: Weights, _ prefix: String, _ dim: Int, eps: Float) throws {
        weight = try w(prefix + ".weight", [dim])
        bias = try w(prefix + ".bias", [dim])
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        layerNorm(x, weight: weight, bias: bias, eps: eps)
    }
}

/// Interleaved rotary embedding (rotary_embedding_torch, `traditional: true` in MLX) over the
/// first `2 * inverseFrequencies.count` features of the last axis, at positions `0..<length` along
/// axis -2. `inverseFrequencies` are the stored `freqs` buffers (`10000^(-2i/d)`), so the angle
/// is `position * freqs[i]`.
struct Rotary {
    let inverseFrequencies: MLXArray  // f32

    init(_ w: Weights, _ name: String, _ count: Int) throws {
        inverseFrequencies = try w(name, [count], dtype: .float32)
    }

    /// cos/sin tables `[length, count]`.
    func tables(length: Int, dtype: DType) -> (MLXArray, MLXArray) {
        let positions = MLXArray((0 ..< length).map { Float($0) }).expandedDimensions(axis: 1)
        let angles = positions * inverseFrequencies.expandedDimensions(axis: 0)
        return (cos(angles).asType(dtype), sin(angles).asType(dtype))
    }

    /// Rotates `x [..., length, d]` with tables from `tables(length:)`; `x` may carry extra axes
    /// between the sequence axis and the features if the tables are broadcast by the caller.
    static func rotate(_ x: MLXArray, cos c: MLXArray, sin s: MLXArray) -> MLXArray {
        let pairs = c.dim(-1)
        let rotated = x[.ellipsis, 0 ..< 2 * pairs]
        let shape = Array(rotated.shape.dropLast()) + [pairs, 2]
        let p = rotated.reshaped(shape)
        let even = p[.ellipsis, 0]
        let odd = p[.ellipsis, 1]
        let outEven = even * c - odd * s
        let outOdd = odd * c + even * s
        let out = stacked([outEven, outOdd], axis: -1).reshaped(rotated.shape)
        if 2 * pairs == x.dim(-1) { return out }
        return concatenated([out, x[.ellipsis, (2 * pairs)...]], axis: -1)
    }
}

func relu(_ x: MLXArray) -> MLXArray { maximum(x, MLXArray(0, dtype: x.dtype)) }
func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }
/// PReLU with one shared slope.
func prelu(_ x: MLXArray, _ a: MLXArray) -> MLXArray { maximum(x, MLXArray(0, dtype: x.dtype)) + a * minimum(x, MLXArray(0, dtype: x.dtype)) }
