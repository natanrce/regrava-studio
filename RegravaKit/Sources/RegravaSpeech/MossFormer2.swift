import Foundation
import MLX

/// MossFormer2_SE_48K (`mossFormer2`, "takes the noise and the room out of the speech"). The network
/// is ClearerVoice's `MossFormer_MaskNet(in_channels: 180, out_channels: 512, out_channels_final:
/// 961, num_blocks: 24)` with one speaker; the trunk runs in float16 with the f16 weights as stored.
final class MossFormer2 {
    /// 12.0 s at 48 kHz (`static MossFormer2.window = 576000`).
    static let window = 576_000
    /// 6.0 s: windows overlap by 50 %.
    static let stride = 288_000
    /// Up to 6 windows per forward (`static MossFormer2.batch = 6`).
    static let batch = 6

    static let nFFT = 1920
    static let hop = 384
    static let melBins = 60
    static let paddedFFT = 2048
    /// ClearerVoice's `MAX_WAV_VALUE`; only the features see the scaled input.
    static let wavScale: Float = 32768

    var masker: Masker
    /// Symmetric Hamming `0.54 − 0.46·cos(2πn/1919)`.
    let hamming: MLXArray
    /// Kaldi mel matrix `[1025, 60]`.
    let melMatrix: MLXArray
    /// Overlap-added `window²` over one 12 s window (`windowWeight`).
    let windowWeight: MLXArray

    init(weights: Weights) throws {
        masker = try Masker(weights)
        let n = Self.nFFT
        let ham = (0 ..< n).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
        hamming = MLXArray(ham.map { Float($0) })
        melMatrix = MLXArray(Self.kaldiMelBanks(), [Self.paddedFFT / 2 + 1, Self.melBins])
        let frames = 1 + (Self.window - n) / Self.hop
        var weight = [Double](repeating: 0, count: Self.window)
        for t in 0 ..< frames { for i in 0 ..< n { weight[t * Self.hop + i] += ham[i] * ham[i] } }
        windowWeight = MLXArray(weight.map { Float($0) })
    }

    // MARK: Windowing

    /// Enhances a whole take: 12 s windows every 6 s, linear crossfade over each 6 s overlap,
    /// the last window filled by reflection, output trimmed to the take (`RemoveNoise`).
    func enhance(_ samples: [Float]) throws -> [Float] {
        let length = samples.count
        if length == 0 { return [] }
        let w = Self.window, s = Self.stride
        let count = length <= w ? 1 : (length - w + s - 1) / s + 1
        var windows: [[Float]] = []
        for k in 0 ..< count {
            let start = k * s
            var segment = Array(samples[start ..< min(start + w, length)])
            if segment.count < w { segment = Self.reflectFill(segment, to: w) }
            windows.append(segment)
        }
        var outputs: [[Float]] = []
        var k = 0
        while k < windows.count {
            let group = Array(windows[k ..< min(k + Self.batch, windows.count)])
            outputs += try enhance(windows: group)
            k += Self.batch
        }
        // `place(_:at:)`: out[i] = (1 − i/n)·old[i] + (i/n)·new[i] over the overlap, then append.
        var out = outputs[0]
        let overlap = w - s
        for k in 1 ..< max(outputs.count, 1) {
            let new = outputs[k]
            let start = k * s
            for i in 0 ..< overlap {
                let a = Float(i) / Float(overlap)
                out[start + i] = (1 - a) * out[start + i] + a * new[i]
            }
            out += new[overlap...]
        }
        return Array(out.prefix(length))
    }

    /// Appends the reversed tail (`Sequence.reversed()`, `flush`). A take shorter than half a window
    /// keeps reflecting back and forth until the window is full.
    static func reflectFill(_ segment: [Float], to size: Int) -> [Float] {
        guard !segment.isEmpty else { return [Float](repeating: 0, count: size) }
        var out = segment
        var forward = false
        while out.count < size {
            let piece = forward ? segment : segment.reversed()
            out += piece.prefix(size - out.count)
            forward.toggle()
        }
        return out
    }

    /// One forward over up to 6 stacked 12 s windows (`MossFormer2.enhance`).
    func enhance(windows: [[Float]]) throws -> [[Float]] {
        let b = windows.count, w = Self.window
        let x = MLXArray(windows.flatMap { $0 }, [b, w])
        let frames = Self.frames(x)  // [B, T, 1920]
        let features = self.features(frames: frames * Self.wavScale)
        let mask = masker(features)  // [B, T, 961] f32
        let spectrum = rfft(frames * hamming, n: Self.nFFT, axis: -1)
        let masked = spectrum * mask
        let time = irfft(masked, n: Self.nFFT, axis: -1) * hamming
        let y = Self.overlapAdd(time, hop: Self.hop) / windowWeight
        eval(y)
        if !isFinite(y.sum()).item(Bool.self) { throw SpeechModelError.notFinite }
        let flat = y.asArray(Float.self)
        return (0 ..< b).map { Array(flat[($0 * w) ..< (($0 + 1) * w)]) }
    }

    // MARK: STFT

    /// Frames of 1920 samples at hop 384, no padding (`center = False`, snip-edges).
    static func frames(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), l = x.dim(1)
        let t = 1 + (l - nFFT) / hop
        return asStrided(x, [b, t, nFFT], strides: [l, hop, 1])
    }

    /// `torch.istft(center=False)` numerator: frames `[B, T, N]` at a hop that divides N.
    static func overlapAdd(_ frames: MLXArray, hop: Int) -> MLXArray {
        let b = frames.dim(0), t = frames.dim(1), n = frames.dim(2)
        let parts = n / hop
        let chunks = frames.reshaped(b, t, parts, hop)
        var sum = MLXArray.zeros([b, t + parts - 1, hop], dtype: frames.dtype)
        for k in 0 ..< parts {
            let piece = chunks[0..., 0..., k, 0...]
            sum = sum + padded(piece, widths: [0, .init((k, parts - 1 - k)), 0])
        }
        return sum.reshaped(b, (t + parts - 1) * hop)
    }

    // MARK: Features: 60 log-mel + Δ + ΔΔ

    /// torchaudio `kaldi.fbank` (dither 0) of frames already scaled by 32768, then
    /// `compute_deltas` twice; returns `[B, T, 180]` f32.
    func features(frames: MLXArray) -> MLXArray {
        var x = frames - frames.mean(axis: -1, keepDims: true)  // remove_dc_offset
        let previous = concatenated([x[.ellipsis, 0 ..< 1], x[.ellipsis, 0 ..< (Self.nFFT - 1)]], axis: -1)
        x = x - 0.97 * previous  // Kaldi pre-emphasis with a replicated first sample
        x = x * hamming
        let spectrum = rfft(x, n: Self.paddedFFT, axis: -1)  // zero pad to 2048
        let power = spectrum.realPart().square() + spectrum.imaginaryPart().square()
        let mel = log(maximum(matmul(power, melMatrix), MLXArray(Float.ulpOfOne)))
        let d1 = Self.deltas(mel)
        let d2 = Self.deltas(d1)
        return concatenated([mel, d1, d2], axis: -1)
    }

    /// torchaudio `compute_deltas(win_length: 5)` along time with edge-replicate padding:
    /// `(2·(x[t+2]−x[t−2]) + (x[t+1]−x[t−1]))/10`.
    static func deltas(_ x: MLXArray) -> MLXArray {
        let t = x.dim(1)
        let p = padded(x, widths: [0, .init((2, 2)), 0], mode: .edge)
        let a = p[0..., 4 ..< (t + 4), 0...] - p[0..., 0 ..< t, 0...]
        let b = p[0..., 3 ..< (t + 3), 0...] - p[0..., 1 ..< (t + 1), 0...]
        return (2 * a + b) / 10
    }

    /// Kaldi `get_mel_banks` (20 Hz to Nyquist, 60 triangles in `1127·ln(1 + f/700)`), padded with a
    /// zero row for the Nyquist bin; `[1025, 60]` row-major.
    static func kaldiMelBanks(sampleRate: Double = 48000) -> [Float] {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let fftBins = paddedFFT / 2
        let binWidth = sampleRate / Double(paddedFFT)
        let low = mel(20), high = mel(sampleRate / 2)
        let delta = (high - low) / Double(melBins + 1)
        var out = [Float](repeating: 0, count: (fftBins + 1) * melBins)
        for m in 0 ..< melBins {
            let left = low + Double(m) * delta, center = left + delta, right = center + delta
            for k in 0 ..< fftBins {
                let v = mel(binWidth * Double(k))
                let up = (v - left) / (center - left)
                let down = (right - v) / (right - center)
                out[k * melBins + m] = Float(max(0, min(up, down)))
            }
        }
        return out
    }
}

// MARK: - Mask network

/// `y = SiLU(norm(x) @ W + b); y = y + depthwise_conv_k17_same(y)` (ClearerVoice `FFConvM` +
/// `ConvModule`).
struct FFConvM {
    enum Norm {
        case scale(g: MLXArray, dim: Int)  // ScaleNorm, FLASH layers
        case layer(LayerNorm)  // LayerNorm eps 1e-5, Gated FSMN
    }

    let norm: Norm
    let linear: Linear
    let depthwise: MLXArray  // [C, 17, 1]

    init(_ w: Weights, _ prefix: String, _ inDim: Int, _ outDim: Int, scaleNorm: Bool) throws {
        if scaleNorm {
            norm = .scale(g: try w(prefix + ".mdl.0.g", [1]), dim: inDim)
        } else {
            norm = .layer(try LayerNorm(w, prefix + ".mdl.0", inDim, eps: 1e-5))
        }
        linear = try Linear(w, prefix + ".mdl.1", inDim, outDim)
        depthwise = depthwiseKernel(try w(prefix + ".mdl.3.sequential.1.conv.weight", [17, outDim]))
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let n: MLXArray
        switch norm {
        case let .scale(g, dim):
            // ScaleNorm: x / max(‖x‖·dim^-0.5, 1e-5) · g. The norm is reduced in f32.
            let x32 = x.asType(.float32)
            let l2 = sqrt(x32.square().sum(axis: -1, keepDims: true)) * Float(pow(Double(dim), -0.5))
            n = (x32 / maximum(l2, MLXArray(Float(1e-5)))).asType(x.dtype) * g
        case let .layer(ln):
            n = ln(x)
        }
        let y = silu(linear(n))
        return y + conv1d(y, depthwise, padding: 8, groups: y.dim(-1))
    }
}

/// Depthwise kernels are stored `[K, C]`; MLX's grouped conv1d wants `[C, K, 1]`.
func depthwiseKernel(_ w: MLXArray) -> MLXArray {
    w.transposed().expandedDimensions(axis: -1)
}

/// `FLASH_ShareA_FFConvM` (dim 512, group 256, qk 128, expansion 4, token shift, non-causal).
struct Flash {
    let toHidden: FFConvM
    let toQK: FFConvM
    let toOut: FFConvM
    let gamma: MLXArray  // [4, 128]
    let beta: MLXArray

    init(_ w: Weights, _ prefix: String) throws {
        toHidden = try FFConvM(w, prefix + ".to_hidden", 512, 2048, scaleNorm: true)
        toQK = try FFConvM(w, prefix + ".to_qk", 512, 128, scaleNorm: true)
        toOut = try FFConvM(w, prefix + ".to_out", 1024, 512, scaleNorm: true)
        gamma = try w(prefix + ".qk_offset_scale.gamma", [4, 128])
        beta = try w(prefix + ".qk_offset_scale.beta", [4, 128])
    }

    func callAsFunction(_ x: MLXArray, rope: (MLXArray, MLXArray)) -> MLXArray {
        let b = x.dim(0), t = x.dim(1), g = 256
        // Token shift: the first 256 channels move down one frame (zero at t = 0).
        let shifted = padded(x[0..., 0 ..< (t - 1), 0 ..< 256], widths: [0, .init((1, 0)), 0])
        let n = concatenated([shifted, x[0..., 0..., 256...]], axis: -1)
        let hidden = toHidden(n)
        let v = hidden[.ellipsis, 0 ..< 1024]
        let u = hidden[.ellipsis, 1024...]
        let qk = toQK(n)  // [B, T, 128]
        // OffsetScale: heads 0..3 = quad_q, lin_q, quad_k, lin_k; RoPE on the first 32 dims of each.
        var heads = qk.expandedDimensions(axis: 2) * gamma + beta  // [B, T, 4, 128]
        heads = Rotary.rotate(heads, cos: rope.0.expandedDimensions(axis: 1), sin: rope.1.expandedDimensions(axis: 1))
        let padding = (g - t % g) % g
        let tp = t + padding
        func pad(_ a: MLXArray) -> MLXArray {
            padding == 0 ? a : padded(a, widths: [0, .init((0, padding)), 0])
        }
        let quadQ = pad(heads[0..., 0..., 0, 0...]), linQ = pad(heads[0..., 0..., 1, 0...])
        let quadK = pad(heads[0..., 0..., 2, 0...]), linK = pad(heads[0..., 0..., 3, 0...])
        let vp = pad(v), up = pad(u)
        let groups = tp / g
        func grouped(_ a: MLXArray) -> MLXArray { a.reshaped(b, groups, g, a.dim(-1)) }
        // attn = relu(q·kᵀ / 256)² per group of 256 frames. The 1/256 is folded into q.
        let sim = matmul(grouped(quadQ * Float(1.0 / Double(g))), grouped(quadK).swappedAxes(-1, -2))
        let attn = relu(sim).square()
        let quadV = matmul(attn, grouped(vp)).reshaped(b, tp, 1024)
        let quadU = matmul(attn, grouped(up)).reshaped(b, tp, 1024)
        // Global linear attention, divided by the unpadded length (folded into lin_k).
        let linKT = (linK * Float(1.0 / Double(t))).swappedAxes(-1, -2)  // [B, 128, Tp]
        let linV = matmul(linQ, matmul(linKT, vp))
        let linU = matmul(linQ, matmul(linKT, up))
        let attV = (quadV + linV)[0..., 0 ..< t, 0...]
        let attU = (quadU + linU)[0..., 0 ..< t, 0...]
        let out = (attU * v) * sigmoid(attV * u)
        return x + toOut(out)
    }
}

/// `Gated_FSMN_Block` (dim 512, inner 256) with `UniDeepFsmn` (lorder 20, k 39).
struct GatedFSMNBlock {
    let conv1: Linear
    let conv1Slope: MLXArray
    let norm1: LayerNorm
    let toU: FFConvM
    let toV: FFConvM
    let fsmnLinear: Linear
    let fsmnProject: Linear
    let fsmnConv: MLXArray  // [256, 39, 1]
    let norm2: LayerNorm
    let conv2: Linear

    init(_ w: Weights, _ prefix: String) throws {
        conv1 = try Linear(w, prefix + ".conv1.0", 512, 256)
        conv1Slope = try w(prefix + ".conv1.1.weight", [1])
        norm1 = try LayerNorm(w, prefix + ".norm1", 256, eps: 1e-5)
        toU = try FFConvM(w, prefix + ".gated_fsmn.to_u", 256, 256, scaleNorm: false)
        toV = try FFConvM(w, prefix + ".gated_fsmn.to_v", 256, 256, scaleNorm: false)
        fsmnLinear = try Linear(w, prefix + ".gated_fsmn.fsmn.linear", 256, 256)
        fsmnProject = try Linear(w, prefix + ".gated_fsmn.fsmn.project", 256, 256, bias: false)
        fsmnConv = depthwiseKernel(try w(prefix + ".gated_fsmn.fsmn.conv1.weight", [39, 256]))
        norm2 = try LayerNorm(w, prefix + ".norm2", 256, eps: 1e-5)
        conv2 = try Linear(w, prefix + ".conv2", 256, 512)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let c = prelu(conv1(x), conv1Slope)
        let n1 = norm1(c)
        let xu = toU(n1)
        let xv = toV(n1)
        // Precision: the FSMN memory and the gate `xv · xu` exceed float16's range (≈1e7 on speech),
        // so this tail runs in f32.
        let f32 = DType.float32
        var f = matmul(relu(fsmnLinear(xu)).asType(f32), fsmnProject.weight.asType(f32))
        f = f + conv1d(f, fsmnConv.asType(f32), padding: 19, groups: 256)
        let u = xu.asType(f32) + f
        let g = xv.asType(f32) * u + n1.asType(f32)
        return x + conv2(layerNorm(g, weight: norm2.weight.asType(f32), bias: norm2.bias.asType(f32), eps: norm2.eps).asType(x.dtype))
    }
}

/// The whole mask network: `[B, T, 180]` f32 features to a `[B, T, 961]` f32 mask.
struct Masker {
    let norm: (MLXArray, MLXArray)
    let encoder: MLXArray
    let invFreq: MLXArray
    let posScale: MLXArray
    let layers: [Flash]
    let fsmn: [GatedFSMNBlock]
    let rotary: Rotary
    let mdlNorm: LayerNorm
    let intraNorm: (MLXArray, MLXArray)
    let preluSlope: MLXArray
    let convOut: Linear
    let output: Linear
    let outputGate: Linear
    let decoder: MLXArray
    /// The trunk's dtype: float16; float32 for validation.
    var compute = DType.float16

    init(_ w: Weights) throws {
        norm = (try w("norm.weight", [180], dtype: .float32), try w("norm.bias", [180], dtype: .float32))
        encoder = try w("conv1d_encoder.weight", [180, 512])
        invFreq = try w("pos_enc.inv_freq", [256], dtype: .float32)
        posScale = try w("pos_enc.scale", [1], dtype: .float32)
        let m = "mdl.intra_mdl.mossformerM"
        layers = try (0 ..< 24).map { try Flash(w, "\(m).layers.\($0)") }
        fsmn = try (0 ..< 24).map { try GatedFSMNBlock(w, "\(m).fsmn.\($0)") }
        rotary = try Rotary(w, "rotary_pos_emb.freqs", 16)
        mdlNorm = try LayerNorm(w, "mdl.intra_mdl.norm", 512, eps: 1e-6)
        intraNorm = (try w("mdl.intra_norm.weight", [512], dtype: .float32), try w("mdl.intra_norm.bias", [512], dtype: .float32))
        preluSlope = try w("prelu.weight", [1])
        convOut = try Linear(w, "conv1d_out", 512, 512)
        output = try Linear(w, "output.0", 512, 512)
        outputGate = try Linear(w, "output_gate.0", 512, 512)
        decoder = try w("conv1_decoder.weight", [512, 961])
    }

    /// GroupNorm(1, C) over all (T, C) of each window, eps 1e-8, in f32.
    static func groupNorm(_ x: MLXArray, _ affine: (MLXArray, MLXArray)) -> MLXArray {
        let x32 = x.asType(.float32)
        let mean = x32.mean(axes: [1, 2], keepDims: true)
        let variance = (x32 - mean).square().mean(axes: [1, 2], keepDims: true)
        return (x32 - mean) / sqrt(variance + 1e-8) * affine.0 + affine.1
    }

    func callAsFunction(_ features: MLXArray) -> MLXArray {
        let t = features.dim(1)
        let half = compute
        var x = matmul(Self.groupNorm(features, norm).asType(half), encoder)
        // ScaledSinuEmbedding: scale · [sin(t·inv_freq), cos(t·inv_freq)], computed in f32.
        let positions = MLXArray((0 ..< t).map { Float($0) }).expandedDimensions(axis: 1)
        let sinu = positions * invFreq.expandedDimensions(axis: 0)
        x = x + (concatenated([sin(sinu), cos(sinu)], axis: -1) * posScale).asType(half)
        let skip = x
        var h = x
        let rope = rotary.tables(length: t, dtype: half)
        for i in 0 ..< 24 {
            h = layers[i](h, rope: rope)
            h = fsmn[i](h)
            if i % 4 == 3 { eval(h) }
        }
        h = mdlNorm(h)
        h = Self.groupNorm(h, intraNorm).asType(half)
        x = prelu(h + skip, preluSlope)
        x = convOut(x)
        x = tanh(output(x)) * sigmoid(outputGate(x))
        return relu(matmul(x, decoder)).asType(.float32)
    }
}
