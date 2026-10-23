import Foundation
import MLX

/// TF-Restormer (`tfRestormer`, "restores the take's speech to full band, its highs up to 17 kHz").
/// The weights are stored f32 and cast to f16 at load; the network runs in f16.
final class TFRestormer {
    static let nFFT = 1920
    static let hop = 960
    static let bins = 961
    /// 750 frames = 15 s per segment. The 375-frame working-set variant's threshold is
    /// UNKNOWN; we always use 750.
    static let segmentFrames = 750
    /// 25 frames (0.5 s) of left and 100 frames (2 s) of right context per segment. The
    /// left context is crossfaded, not discarded (read from `segment`).
    static let leftContext = 25
    static let rightContext = 100

    let network: Network
    /// Periodic sqrt-Hann divided by √960.
    let window: [Float]

    init(weights: Weights) throws {
        network = try Network(weights)
        window = (0 ..< Self.nFFT).map {
            Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.nFFT))) / sqrt(960.0))
        }
    }

    // MARK: Band (`Bins.init(contentUpTo:)`)

    /// Input bins `F_E` and output bins `F_D` for a take with content up to `contentUpTo` Hz.
    static func bins(contentUpTo hz: Double) -> (input: Int, output: Int) {
        let f = min(max(hz, 0), 24000)
        let n = Int((f / 25).rounded()) + 1
        var fe = Int((Double(n + 8) / 6).rounded(.up)) * 6
        if fe < 162 { return (161, 684) }
        fe = min(fe, 961)
        return (fe, min(max(fe, 684), 961))
    }

    // MARK: Whole take

    /// Restores a 48 kHz mono take; the output has the input's length.
    func restore(_ samples: [Float], contentUpTo hz: Double) throws -> [Float] {
        let length = samples.count
        if length == 0 { return [] }
        let (fe, fd) = Self.bins(contentUpTo: hz)
        // Framing: 960 zeros before the take so every sample lies under two frames, and at least
        // 1920 after it (`finish(_:)` pads the tail with at least 1920 samples).
        let frameCount = (length + Self.hop - 1) / Self.hop + 1
        var source = [Float](repeating: 0, count: (frameCount + 1) * Self.hop)
        source.replaceSubrange(Self.hop ..< (Self.hop + length), with: samples)
        let spectrum = analyze(source, frames: frameCount)  // [T, 961] complex
        let (re, im) = (spectrum.realPart(), spectrum.imaginaryPart())
        let scales = Self.scales(levels: abs(spectrum).mean(axis: 1).asArray(Float.self))
        // `Bins.scale16k` = √3: a band-limited input (F_E < 961) enters the network divided by √3 and
        // its output is multiplied back (`TFRestormer.segment`).
        let bandScale: Float = fe == Self.bins ? 1 : Float(3).squareRoot()
        let input = stacked([re[0..., 0 ..< fe], im[0..., 0 ..< fe]], axis: -1) / bandScale  // [T, F_E, 2]
        eval(input)

        // Segments of 750 frames fed with 25 frames of left and 100 of right context. The 25 left-context
        // frames are crossfaded linearly (`linspace(0, 1, count: 25)` in `segment`) into the previous
        // segment's last 25 frames; the right context is discarded.
        var pieces: [MLXArray] = []
        var start = 0
        while start < frameCount {
            let end = min(start + Self.segmentFrames, frameCount)
            let a = max(0, start - Self.leftContext), b = min(frameCount, end + Self.rightContext)
            let scale = MLXArray(Array(scales[a ..< b]), [b - a, 1, 1])
            let y = network(spectrum: input[a ..< b], scale: scale, outputBins: fd, inputBins: fe) * bandScale
            if a < start, let previous = pieces.popLast() {
                let n = start - a
                let ramp = MLXArray((0 ..< n).map { Float($0) / Float(max(n - 1, 1)) }, [n, 1, 1])
                let old = previous[(previous.dim(0) - n)...]
                let faded = (1 - ramp) * old + ramp * y[0 ..< n]
                pieces.append(previous[0 ..< (previous.dim(0) - n)])
                pieces.append(faded)
            }
            let kept = y[(start - a) ..< (end - a)]
            eval(kept)
            pieces.append(kept)
            start = end
        }
        var y = concatenated(pieces, axis: 0)  // [T, F_D, 2] f32
        if fd < Self.bins { y = padded(y, widths: [0, .init((0, Self.bins - fd)), 0]) }  // bins ≥ F_D are zero
        let out = synthesize(re: y[0..., 0..., 0], im: y[0..., 0..., 1], frames: frameCount)
        guard out.allSatisfy({ $0.isFinite }) else { throw SpeechModelError.notFinite }
        return Array(out[Self.hop ..< (Self.hop + length)])
    }

    // MARK: STFT

    /// `rfft(n: 1920)` of each 1920-sample frame at hop 960 times the analysis window.
    func analyze(_ padded: [Float], frames: Int) -> MLXArray {
        let x = MLXArray(padded)
        let f = asStrided(x, [frames, Self.nFFT], strides: [Self.hop, 1])
        return rfft(f * MLXArray(window), n: Self.nFFT, axis: -1)
    }

    /// `TFRestormer.synthesize`: the spectrum times a bin vector of 0.5 with 1.0 at DC and Nyquist,
    /// `irfft`, the window, ×1920, overlap-add at hop 960. For bins other than DC and Nyquist this
    /// is the exact inverse of `analyze` (sqrt-Hann at 50 % overlap); the network's outputs are on
    /// the doubled scale this undoes.
    func synthesize(re: MLXArray, im: MLXArray, frames: Int) -> [Float] {
        let weights = MLXArray((0 ..< Self.bins).map { $0 == 0 || $0 == Self.bins - 1 ? Float(1) : 0.5 })
        let spectrum = (re.asType(.complex64) + MLXArray(real: 0, imaginary: 1) * im.asType(.complex64)) * weights
        let time = irfft(spectrum, n: Self.nFFT, axis: -1) * (MLXArray(window) * Float(1920))
        let y = MossFormer2.overlapAdd(time.expandedDimensions(axis: 0), hop: Self.hop)
        eval(y)
        return y.asArray(Float.self)
    }

    /// `scale[t] = mean(level[t−100 … t+100]) + 1e-8`, clipped to the available frames, with
    /// `level[t]` the mean magnitude over all 961 bins (`Restoration.scales`).
    static func scales(levels: [Float]) -> [Float] {
        var prefix = [Double](repeating: 0, count: levels.count + 1)
        for (i, v) in levels.enumerated() { prefix[i + 1] = prefix[i] + Double(v) }
        return (0 ..< levels.count).map { t in
            let a = max(0, t - 100), b = min(levels.count, t + 101)
            return Float((prefix[b] - prefix[a]) / Double(b - a) + 1e-8)
        }
    }
}

// MARK: - Network

/// ConvSwiGLU FFN with a residual: `LayerNorm` (eps 1e-5), conv k7 C→6C, `silu(g) · v`, conv k7 3C→C: both
/// convolutions are cross-correlations with zero "same" padding of 3, the intermediate is zero outside the
/// sequence, and the FIRST half of `net1`'s outputs is the gate, the second the value.
struct ConvSwiGLU {
    let norm: LayerNorm
    let w1: MLXArray, b1: MLXArray
    let w2: MLXArray, b2: MLXArray
    let inner: Int

    init(_ w: Weights, _ prefix: String, _ dim: Int) throws {
        norm = try LayerNorm(w, prefix + ".layernorm", dim, eps: 1e-5)
        inner = 3 * dim
        w1 = try w(prefix + ".net1.weight", [2 * inner, 7, dim])
        b1 = try w(prefix + ".net1.bias", [2 * inner])
        w2 = try w(prefix + ".net2.weight", [dim, 7, inner])
        b2 = try w(prefix + ".net2.bias", [dim])
    }

    /// `x [N, L, C]` (sequences along axis 1) to `x + FFN(x)`.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = conv1d(norm(x), w1, padding: 3) + b1  // [N, L, 6C]
        let gated = silu(h[.ellipsis, 0 ..< inner]) * h[.ellipsis, inner...]
        return x + conv1d(gated, w2, padding: 3) + b2
    }
}

/// Multi-head self-attention (TF-Locoformer `MultiHeadSelfAttention`): LayerNorm, `qkv` without bias
/// reshaped `[…, 3, heads, d]`, softmax attention with scale `1/√d`, `aggregate_heads`.
struct SelfAttention {
    let norm: LayerNorm
    let qkv: MLXArray
    let out: MLXArray
    let heads = 4
    static let bandWidth = 100

    /// Additive mask `[L, L]`: 0 where `i − 100 ≤ j < i + 100`, −inf elsewhere.
    static func band(_ l: Int, dtype: DType) -> MLXArray? {
        if l <= bandWidth { return nil }
        let i = MLXArray(Array(0 ..< l).map { Int32($0) }).expandedDimensions(axis: 1)
        let j = MLXArray(Array(0 ..< l).map { Int32($0) }).expandedDimensions(axis: 0)
        let inside = logicalAnd(j + Int32(bandWidth) .>= i, j .< i + Int32(bandWidth))
        return which(inside, MLXArray(Float(0)), MLXArray(-Float.infinity)).asType(dtype)
    }

    init(_ w: Weights, _ prefix: String, _ dim: Int) throws {
        norm = try LayerNorm(w, prefix + ".layer_norm", dim, eps: 1e-5)
        qkv = try w(prefix + ".block.qkv.weight", [dim, 3 * dim])
        out = try w(prefix + ".block.aggregate_heads.0.weight", [dim, dim])
    }

    /// `x [N, L, C]`. Time modules pass RoPE tables; frequency modules pass the shared `Ekv1`
    /// projection, which maps keys and values from L rows to 512 (paper Eq. 1-2).
    func callAsFunction(_ x: MLXArray, rope: (MLXArray, MLXArray)? = nil, projection: MLXArray? = nil) -> MLXArray {
        let n = x.dim(0), l = x.dim(1), c = x.dim(2), d = c / heads
        let p = matmul(norm(x), qkv).reshaped(n, l, 3, heads, d).transposed(2, 0, 3, 1, 4)  // [3, N, H, L, d]
        var q = p[0], k = p[1], v = p[2]
        if let rope {
            q = Rotary.rotate(q, cos: rope.0, sin: rope.1)
            k = Rotary.rotate(k, cos: rope.0, sin: rope.1)
        }
        if let projection {
            let a = projection[0..., 0..., 0 ..< l]  // [H, 512, L]: Ekv1[h][:, :L] @ K_h == A_hᵀ·[K_h ; 0]
            k = matmul(a, k)
            v = matmul(a, v)
        }
        // Time modules attend within a band: key j is seen by query i when i − 100 ≤ j < i + 100
        // (`BAND = 100` template argument of the attention kernel in `Network.attend`).
        let mask = rope == nil ? nil : Self.band(l, dtype: x.dtype)
        let o = scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1 / Float(d).squareRoot(), mask: mask)
        return x + matmul(o.transposed(0, 2, 1, 3).reshaped(n, l, c), out)
    }
}

/// `ffn_1`, `sa`, `ffn_2` with full residuals (TF-Locoformer macaron block without the 0.5 factor).
struct MacaronBlock {
    let ffn1: ConvSwiGLU
    let sa: SelfAttention
    let ffn2: ConvSwiGLU

    init(_ w: Weights, _ prefix: String, _ dim: Int) throws {
        ffn1 = try ConvSwiGLU(w, prefix + ".ffn_1", dim)
        sa = try SelfAttention(w, prefix + ".sa", dim)
        ffn2 = try ConvSwiGLU(w, prefix + ".ffn_2", dim)
    }

    func callAsFunction(_ x: MLXArray, rope: (MLXArray, MLXArray)? = nil, projection: MLXArray? = nil) -> MLXArray {
        ffn2(sa(ffn1(x), rope: rope, projection: projection))
    }
}

/// Decoder along-frequency module: cross-attention from the extension bins to the encoder output,
/// projected self-attention over all output bins, one FFN (`decoderBlock`).
struct DecoderFrequencyBlock {
    let normQ: LayerNorm
    let q: MLXArray
    let kv: MLXArray
    let caOut: MLXArray
    let sa: SelfAttention
    let ffn: ConvSwiGLU

    init(_ w: Weights, _ prefix: String) throws {
        normQ = try LayerNorm(w, prefix + ".ca.layer_norm_q", 64, eps: 1e-5)
        q = try w(prefix + ".ca.block.q.weight", [64, 64])
        kv = try w(prefix + ".ca.block.kv.weight", [128, 128])
        caOut = try w(prefix + ".ca.block.aggregate_heads.0.weight", [64, 64])
        sa = try SelfAttention(w, prefix + ".sa", 64)
        ffn = try ConvSwiGLU(w, prefix + ".ffn", 64)
    }

    /// `d [T, F_D, 64]`, `encoded [T, F_E, 128]`.
    func callAsFunction(_ d: MLXArray, encoded e: MLXArray, projection: MLXArray) -> MLXArray {
        var d = d
        let t = d.dim(0), fd = d.dim(1), fe = e.dim(1), heads = 4, hd = 16
        if fe < fd {  // Skipped when F_E ≥ F_D (paper: "applied only when f_E < f_D")
            let ext = d[0..., fe..., 0...]
            let fx = fd - fe
            let qh = matmul(normQ(ext), q).reshaped(t, fx, heads, hd).transposed(0, 2, 1, 3)
            let kvh = matmul(e, kv).reshaped(t, fe, 2, heads, hd).transposed(2, 0, 3, 1, 4)
            // The keys/values of the cross-attention get the same frequency projection.
            let a = projection[0..., 0..., 0 ..< fe]
            let k = matmul(a, kvh[0]), v = matmul(a, kvh[1])
            let o = scaledDotProductAttention(queries: qh, keys: k, values: v, scale: 1 / Float(hd).squareRoot(), mask: nil)
            let added = ext + matmul(o.transposed(0, 2, 1, 3).reshaped(t, fx, 64), caOut)
            d = concatenated([d[0..., 0 ..< fe, 0...], added], axis: 1)
        }
        return ffn(sa(d, projection: projection))
    }
}

/// `Network.callAsFunction(spectrum:scale:positions:outputBins:)`.
final class Network {
    let embed: MLXArray, embedBias: MLXArray
    let embedNorm: LayerNorm
    let encoderRope: Rotary
    let encoderFrequency: [MacaronBlock]
    let encoderTime: [MacaronBlock]
    let encoderNorm: LayerNorm
    let projection: MLXArray  // shared.Ekv1 [4, 512, 961]
    let up: Linear
    let maskToken: MLXArray  // [800, 64]
    let upNorm: LayerNorm
    let decoderRope: Rotary
    let decoderFrequency: [DecoderFrequencyBlock]
    let decoderTime: [MacaronBlock]
    let decoderNorm: LayerNorm
    let magnitude: MLXArray, magnitudeBias: MLXArray
    let phase: MLXArray, phaseBias: MLXArray
    /// Sequences evaluated at once, bounding memory.
    let chunk = 48

    init(_ w: Weights) throws {
        // Tested: the 3x3 kernels' first spatial axis runs along frequency and the second along time.
        // With our [T, F] layout we swap them; the other order leaves the output barely correlated
        // with the input band (in-band correlation 0.27 vs 0.86 on speech).
        embed = try w("input_embed.embed.weight", [128, 3, 3, 2]).transposed(0, 2, 1, 3)
        embedBias = try w("input_embed.embed.bias", [128])
        embedNorm = try LayerNorm(w, "input_embed.layernorm", 128, eps: 1e-5)
        encoderRope = try Rotary(w, "encoder.rope.freqs", 16)
        encoderFrequency = try (0 ..< 6).map { try MacaronBlock(w, "encoder.tf_block.\($0).frame_wise_block.block", 128) }
        encoderTime = try (0 ..< 6).map { try MacaronBlock(w, "encoder.tf_block.\($0).freq_wise_block.block", 128) }
        encoderNorm = try LayerNorm(w, "encoder.layer_norm", 128, eps: 1e-5)
        projection = try w("shared.Ekv1", [4, 512, 961])
        up = try Linear(w, "up.proj", 128, 64)
        maskToken = try w("up.mask_token", [1, 800, 1, 64]).reshaped(800, 64)
        upNorm = try LayerNorm(w, "up.layernorm", 64, eps: 1e-5)
        decoderRope = try Rotary(w, "decoder.rope.freqs", 8)
        decoderFrequency = try (0 ..< 3).map { try DecoderFrequencyBlock(w, "decoder.tf_block.\($0).frame_wise_block.block") }
        decoderTime = try (0 ..< 3).map { try MacaronBlock(w, "decoder.tf_block.\($0).freq_wise_block.block", 64) }
        decoderNorm = try LayerNorm(w, "decoder.layer_norm", 64, eps: 1e-5)
        magnitude = try w("estimator.mag.out.0.weight", [1, 3, 3, 64], dtype: .float32).transposed(0, 2, 1, 3)
        magnitudeBias = try w("estimator.mag.out.0.bias", [1], dtype: .float32)
        phase = try w("estimator.phase.out.0.weight", [2, 3, 3, 64], dtype: .float32).transposed(0, 2, 1, 3)
        phaseBias = try w("estimator.phase.out.0.bias", [2], dtype: .float32)
    }

    /// `frequencyPositions(bins:)`: `pe[f,k] = sin(f·exp(−k·ln(10000)/63))`, `pe[f,64+k] = cos(…)`
    /// for absolute bin index `f`, computed in f32.
    static func frequencyPositions(bins: Int) -> MLXArray {
        let f = MLXArray((0 ..< bins).map { Float($0) }).expandedDimensions(axis: 1)
        let k = MLXArray((0 ..< 64).map { Float(exp(-Double($0) * log(10000.0) / 63)) }).expandedDimensions(axis: 0)
        return concatenated([sin(f * k), cos(f * k)], axis: -1)
    }

    /// Applies `body` to slices of `x` along axis 0, evaluating each slice to bound memory.
    func chunked(_ x: MLXArray, _ body: (MLXArray) -> MLXArray) -> MLXArray {
        let n = x.dim(0)
        if n <= chunk { let y = body(x); eval(y); return y }
        var parts: [MLXArray] = []
        var i = 0
        while i < n {
            let y = body(x[i ..< min(i + chunk, n)])
            eval(y)
            parts.append(y)
            i += chunk
        }
        return concatenated(parts, axis: 0)
    }

    /// `spectrum [T, F_E, 2]` (re, im), `scale [T, 1, 1]`; returns `[T, F_D, 2]` f32 = mag · pha · scale.
    func callAsFunction(spectrum: MLXArray, scale: MLXArray, outputBins fd: Int, inputBins fe: Int) -> MLXArray {
        let half = DType.float16
        let t = spectrum.dim(0)
        // 1-3: scale normalization, 3x3 conv embedding over (T, F), LayerNorm, frequency positions.
        let x0 = (spectrum / scale).asType(half).expandedDimensions(axis: 0)
        var x = conv2d(x0, embed, padding: 1)[0] + embedBias
        x = embedNorm(x) + Self.frequencyPositions(bins: fe).asType(half)
        eval(x)
        // 4: encoder blocks, along frequency (per frame) then along time (per bin).
        let encRope = encoderRope.tables(length: t, dtype: half)
        for i in 0 ..< 6 {
            x = chunked(x) { encoderFrequency[i]($0, projection: projection) }
            let xt = chunked(x.transposed(1, 0, 2)) { encoderTime[i]($0, rope: encRope) }
            x = xt.transposed(1, 0, 2)
        }
        // 5: encoder norm, up-projection, learnable extension queries, LayerNorm (concat, then norm).
        let e = encoderNorm(x)
        var d = up(e)
        if fd > fe {
            let tokens = maskToken[(fe - 161) ..< (fd - 161)].expandedDimensions(axis: 0)
            d = concatenated([d, broadcast(tokens, to: [t, fd - fe, 64])], axis: 1)
        }
        d = upNorm(d)
        eval(e, d)
        // 6: decoder blocks.
        let decRope = decoderRope.tables(length: t, dtype: half)
        for i in 0 ..< 3 {
            var parts: [MLXArray] = []
            var s = 0
            while s < t {
                let r = s ..< min(s + chunk, t)
                let y = decoderFrequency[i](d[r], encoded: e[r], projection: projection)
                eval(y)
                parts.append(y)
                s += chunk
            }
            d = concatenated(parts, axis: 0)
            let dt = chunked(d.transposed(1, 0, 2)) { decoderTime[i]($0, rope: decRope) }
            d = dt.transposed(1, 0, 2)
        }
        // 7: estimator. mag = softplus (`logAddExp(x, 0)`), pha = tanh, both f32; Y = mag · pha · scale.
        let h = decoderNorm(d).asType(.float32).expandedDimensions(axis: 0)
        let mag = logAddExp(conv2d(h, magnitude, padding: 1)[0] + magnitudeBias, MLXArray(Float(0)))
        let pha = tanh(conv2d(h, phase, padding: 1)[0] + phaseBias)
        return mag * pha * scale
    }
}
