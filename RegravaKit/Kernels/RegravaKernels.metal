// Core Image kernels of the renderer. Rebuild Sources/RegravaRender/RegravaKernels.metallib
// after editing (xcrun metal -c -fcikernel, then xcrun metallib -cikernel).
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// Motion blur sample weighted by the falloff, 1 + ratio * smoothstep(0, 1, 1 - alpha).
float4 motionBlurWeighted(sample_t s, float ratio) {
    float w = 1.0 + ratio * smoothstep(0.0, 1.0, 1.0 - s.a);
    return s * w;
}

/// The same weight alone, in every channel.
float4 motionBlurWeight(sample_t s, float ratio) {
    float w = 1.0 + ratio * smoothstep(0.0, 1.0, 1.0 - s.a);
    return float4(w);
}

/// Weighted sum divided by the total weight.
float4 motionBlurNormalize(sample_t total, sample_t weight) {
    return weight.r > 0.0 ? total / weight.r : float4(0.0);
}

/// Bilinear field between the four quadrant colours of a mask, one per corner of `rect`
/// (the 2x2 texture sampled at uv * 0.5 + 0.25).
float4 maskCover(sampler colors, float4 rect, destination dest) {
    float2 p = clamp((dest.coord() - rect.xy) / rect.zw, 0.0, 1.0);
    return colors.sample(colors.transform(p + float2(0.5)));
}

/// Simplified AMD CAS of the camera sharpen: 4 neighbours one texel away, peak weight -0.2,
/// headroom min(mn, 2 - mx).
float3 casStraight(sampler s, float2 p) {
    float4 t = s.sample(s.transform(p));
    return t.rgb / max(t.a, 0.001);
}

float4 casSharpen(sampler image, float amount, destination dest) {
    float2 p = dest.coord();
    float4 center = image.sample(image.transform(p));
    if (amount < 0.001) return center;
    float a = center.a;
    float3 c = center.rgb / max(a, 0.001);
    float3 up = casStraight(image, p + float2(0.0, 1.0));
    float3 down = casStraight(image, p - float2(0.0, 1.0));
    float3 left = casStraight(image, p - float2(1.0, 0.0));
    float3 right = casStraight(image, p + float2(1.0, 0.0));
    float3 sum = up + down + left + right;
    float3 mn = min(min(up, down), min(min(left, right), c));
    float3 mx = max(max(up, down), max(max(left, right), c));
    float3 headroom = min(mn, float3(2.0) - mx);
    float3 cas = sqrt(clamp(headroom / max(mx, float3(0.001)), 0.0, 1.0));
    float3 w = cas * (-0.2 * amount);
    float3 result = clamp((c + sum * w) / (w * 4.0 + 1.0), 0.0, 1.0);
    return float4(result * a, a);
}

// MARK: Camera cutout

static float cutoutInside(float2 p, float4 bounds) {
    return (p.x >= bounds.x && p.y >= bounds.y && p.x <= bounds.x + bounds.z && p.y <= bounds.y + bounds.w) ? 1.0 : 0.0;
}

static float cutoutMatteAt(sampler matte, float2 p, float4 bounds) {
    return matte.sample(matte.transform(p)).r * cutoutInside(p, bounds);
}

static float3 cutoutGuide(sampler frame, float2 p, float2 offset) {
    float3 sum = frame.sample(frame.transform(p + float2(-offset.x, -offset.y))).rgb
        + frame.sample(frame.transform(p + float2(offset.x, -offset.y))).rgb
        + frame.sample(frame.transform(p + float2(-offset.x, offset.y))).rgb
        + frame.sample(frame.transform(p + float2(offset.x, offset.y))).rgb;
    return sum * 0.25;
}

/// `compositeMatte`: the low-resolution matte upsampled into the frame with a 3×3
/// joint-bilateral filter guided by the footage, except where the matte is solid.
/// `texelPx` = frame pixels per matte texel; `bounds` = frame extent. Returns the alpha.
float4 cutoutMatteAlpha(sampler frame, sampler matte, float2 texelPx, float4 bounds, destination dest) {
    const float spatialFalloff = -0.5 / (0.8 * 0.8);
    const float rangeFalloff = -0.5 / (0.12 * 0.12);
    const float solidEpsilon = 0.004;
    float2 p = dest.coord();
    float3 color = frame.sample(frame.transform(p)).rgb;
    float alpha = cutoutMatteAt(matte, p, bounds);
    bool isSolid = true;
    for (int ty = -2; ty <= 2 && isSolid; ty += 2) {
        for (int tx = -2; tx <= 2 && isSolid; tx += 2) {
            float tap = cutoutMatteAt(matte, p + float2(tx, ty) * texelPx, bounds);
            isSolid = abs(tap - alpha) < solidEpsilon && (alpha < solidEpsilon || alpha > 1.0 - solidEpsilon);
        }
    }
    if (!isSolid) {
        float num = 0.0, den = 0.0;
        for (int ty = -1; ty <= 1; ty++) {
            for (int tx = -1; tx <= 1; tx++) {
                float2 o = float2(tx, ty);
                float2 q = p + o * texelPx;
                float3 guide = cutoutGuide(frame, q, texelPx * 0.5);
                float3 d = guide - color;
                float w = exp(dot(o, o) * spatialFalloff + dot(d, d) * rangeFalloff);
                num += w * cutoutMatteAt(matte, q, bounds);
                den += w;
            }
        }
        alpha = num / max(den, 1e-4);
    }
    return float4(alpha);
}

/// `getRevealAt`: a circle growing from the crop window's centre to its corners.
static float cutoutReveal(float2 p, float2 frameSize, float4 window, float2 norm, float reveal) {
    float2 uv = p / frameSize;
    float2 w = (uv - window.xy) / window.zw;
    float cornerDistance = length((w - 0.5) * norm);
    float radius = mix(-0.25, 1.25, reveal);
    return reveal * (1.0 - smoothstep(radius - 0.25, radius + 0.25, cornerDistance));
}

/// `source/masked-video`: edge inset (1-step min erosion), edge softness, background reveal.
/// `alphaMip` is the alpha averaged over `solidLod`. params = (softness01, reveal01, insetPx,
/// texelPx); geometry = (frame w, frame h, norm.x, norm.y).
float4 cutoutEdge(sampler frame, sampler alpha, sampler alphaMip, float4 params, float4 geometry, float4 window, destination dest) {
    float2 p = dest.coord();
    float softness = params.x, reveal = params.y, inset = params.z, texelPx = params.w;
    float3 rgb = frame.sample(frame.transform(p)).rgb;
    float coverage = alpha.sample(alpha.transform(p)).r;
    if (reveal < 1.0) {
        float n = alphaMip.sample(alphaMip.transform(p)).r;
        bool isSolid = n < 0.004 || n > 0.996;
        if (!isSolid && inset > 0.0) {
            float h = min(alpha.sample(alpha.transform(p - float2(inset, 0))).r, alpha.sample(alpha.transform(p + float2(inset, 0))).r);
            float v = min(alpha.sample(alpha.transform(p - float2(0, inset))).r, alpha.sample(alpha.transform(p + float2(0, inset))).r);
            coverage = min(coverage, min(h, v));
        }
        if (!isSolid && softness < 1.0) {
            float partial = 0.0;
            for (int ty = -2; ty <= 2; ty++) {
                for (int tx = -2; tx <= 2; tx++) {
                    float a = alpha.sample(alpha.transform(p + float2(tx, ty) * texelPx)).r;
                    partial += 4.0 * a * (1.0 - a);
                }
            }
            float fineness = smoothstep(0.25, 0.45, partial / 25.0);
            float crisp = smoothstep(0.4, 0.6, coverage);
            coverage = mix(coverage, crisp, (1.0 - softness) * (1.0 - fineness));
        }
    }
    if (reveal > 0.0) {
        coverage += (1.0 - coverage) * cutoutReveal(p, geometry.xy, window, geometry.zw, reveal);
    }
    return float4(rgb * coverage, coverage);
}

static float3 cutoutBackgroundMean(float3 footageMean, float4 composeMean) {
    return (footageMean - composeMean.rgb) / max(1.0 - composeMean.a, 1e-4);
}

static float3 cutoutFuse(float3 image, float a, float3 fgMean, float3 bgMean) {
    float3 residual = image - fgMean * a - bgMean * (1.0 - a);
    return clamp(fgMean + residual * a, 0.0, 1.0);
}

/// `source/masked-video-foreground-coarse`.
float4 cutoutForegroundCoarse(sampler compose, sampler footage, sampler composeMean, sampler footageMean, destination dest) {
    float2 p = dest.coord();
    float a = compose.sample(compose.transform(p)).a;
    float3 image = footage.sample(footage.transform(p)).rgb;
    float4 cm = composeMean.sample(composeMean.transform(p));
    float3 fm = footageMean.sample(footageMean.transform(p)).rgb;
    float3 fg = cutoutFuse(image, a, cm.rgb / max(cm.a, 1e-4), cutoutBackgroundMean(fm, cm));
    float w = a * a * a * a;
    return float4(fg * w, w);
}

/// `source/masked-video-foreground`: colour decontamination of partial pixels, then the
/// background reveal. params = (reveal01, norm.x, norm.y, 0).
float4 cutoutForeground(sampler compose, sampler footage, sampler composeMean, sampler footageMean, sampler personMean, sampler wideMean,
                        float4 params, float4 window, float2 frameSize, destination dest) {
    float2 p = dest.coord();
    float a = compose.sample(compose.transform(p)).a;
    float3 image = footage.sample(footage.transform(p)).rgb;
    float3 premul = image * a;
    if (a > 0.0 && a < 1.0) {
        float4 cm = composeMean.sample(composeMean.transform(p));
        float3 fm = footageMean.sample(footageMean.transform(p)).rgb;
        float4 person = personMean.sample(personMean.transform(p));
        float4 wide = wideMean.sample(wideMean.transform(p));
        float hasPerson = smoothstep(0.002, 0.02, person.a);
        float3 fgMean = mix(wide.rgb / max(wide.a, 1e-4), person.rgb / max(person.a, 1e-4), hasPerson);
        float3 bgMean = cutoutBackgroundMean(fm, cm);
        float3 fg = cutoutFuse(image, a, fgMean, bgMean);
        float3 line = fg - bgMean;
        float sep = length(line);
        float explained = dot(image - bgMean, line) / max(sep * sep, 1e-4);
        float margin = (0.04 / max(sep, 0.001)) * 2.0;
        float bounded = min(a, max(explained, 0.0) + margin);
        a = mix(a, bounded, smoothstep(0.15, 0.45, sep));
        premul = fg * a;
    }
    float reveal = params.x;
    if (reveal > 0.0) {
        float r = cutoutReveal(p, frameSize, window, params.yz, reveal);
        premul += (image - premul) * r;
        a += (1.0 - a) * r;
    }
    return float4(premul, a);
}


// MARK: Smooth corners and shadows

/// smoothstep that also accepts edge0 > edge1, as the shaders use it.
float rampStep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// `curvatureLut` lookup by the angle of `d`.
float curvatureRatio(float2 d, float4 l0, float4 l1, float4 l2, float4 l3) {
    if (d.x <= 0.0 || d.y <= 0.0) return 1.0;
    float lut[16] = { l0.x, l0.y, l0.z, l0.w, l1.x, l1.y, l1.z, l1.w, l2.x, l2.y, l2.z, l2.w, l3.x, l3.y, l3.z, l3.w };
    float t = atan(min(d.x, d.y) / max(d.x, d.y)) * 15.0 / (M_PI_F / 4.0);
    t = clamp(t, 0.0, 15.0);
    int i = min(int(floor(t)), 14);
    return mix(lut[i], lut[i + 1], t - float(i));
}

/// Signed distance to the smooth-cornered rect of half size `h` and corner extent `R`.
float smoothRectSD(float2 p, float2 h, float R, float4 l0, float4 l1, float4 l2, float4 l3) {
    float2 d = abs(p) - (h - R);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - R * curvatureRatio(d, l0, l1, l2, l3);
}

/// Signed distance to a circular-cornered rect.
float circleRectSD(float2 p, float2 h, float r) {
    float2 q = abs(p) - (h - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

/// Circular far from the body, blending into the smooth corner close to it.
float casterSD(float2 p, float2 h, float R, float rs, float4 l0, float4 l1, float4 l2, float4 l3) {
    float circ = circleRectSD(p, h, rs);
    float Rm = max(R, 1.0);
    if (circ >= Rm) return circ;
    return mix(smoothRectSD(p, h, R, l0, l1, l2, l3), circ, clamp(circ / Rm, 0.0, 1.0));
}

/// Coverage of a smooth-cornered rect: shape = (centre, half size), corner = (R, aa, edge, -).
/// 1 inside `sd < edge`, with a 2·aa ramp (`smoothstep(edge + aa, edge − aa, sd)`).
float4 smoothRectCoverage(float4 shape, float4 corner, float4 l0, float4 l1, float4 l2, float4 l3, destination dest) {
    float sd = smoothRectSD(dest.coord() - shape.xy, shape.zw, corner.x, l0, l1, l2, l3);
    return float4(rampStep(corner.z + corner.y, corner.z - corner.y, sd));
}

/// Black shadow of a part: corner = (R, rs, aa, directional), shadow = (blur, offset.xy,
/// alpha), light = (position.xy relative to the centre, lightRadius, falloff), unit = local
/// units per pixel for the ray-march steps.
float4 partShadow(float4 shape, float4 corner, float4 shadow, float4 light, float unit,
                  float4 l0, float4 l1, float4 l2, float4 l3, destination dest) {
    float2 p = dest.coord() - shape.xy;
    float2 h = shape.zw;
    float R = corner.x, rs = corner.y, aa = corner.z;
    float mask;
    if (corner.w > 0.5) {
        float proximity = 1.0 - clamp(casterSD(p, h, R, rs, l0, l1, l2, l3) / max(light.w, 0.001), 0.0, 1.0);
        if (proximity <= 0.001) return float4(0.0);
        float2 toLight = light.xy - p;
        float D = max(length(toLight), unit);
        float2 dir = toLight / D;
        float hardness = D / max(light.z, unit);
        float vis = 1.0;
        float t = 2.0 * unit;
        for (int i = 0; i < 12; i++) {
            if (t >= D || vis < -0.5) break;
            float c = casterSD(p + dir * t, h, R, rs, l0, l1, l2, l3);
            vis = min(vis, hardness * c / t);
            t += max(c, 3.0 * unit);
        }
        mask = (1.0 - clamp(vis, 0.0, 1.0)) * proximity * proximity;
    } else {
        float blur = shadow.x;
        mask = rampStep(blur + aa, -0.5 * blur - aa, casterSD(p - shadow.yz, h, R, rs, l0, l1, l2, l3));
    }
    return float4(0.0, 0.0, 0.0, shadow.w * mask);
}


// MARK: Glass loupe
// Lengths are canvas pixels; `rel` is the position relative to the lens centre (y up).

struct LoupeParams {
    float2 center; float radius; float bevel;
    float zoom; float chroma; float presence; float shadowAlpha;
    float2 light; float shineExponent; float lightTilt;
    float shadowSize; float maxReads;
};

LoupeParams loupeParams(float4 g0, float4 g1, float4 g2, float4 g3) {
    LoupeParams L;
    L.center = g0.xy; L.radius = g0.z; L.bevel = g0.w;
    L.zoom = max(g1.x, 0.05); L.chroma = g1.y; L.presence = g1.z; L.shadowAlpha = g1.w;
    L.light = g2.xy; L.shineExponent = g2.z; L.lightTilt = g2.w;
    L.shadowSize = g3.x; L.maxReads = g3.y;
    return L;
}

float bevelArcSlope(float t) {
    float t2 = t * t;
    return min(t2 * rsqrt(1.0 - min(t2, 0.99)), 6.0);
}

/// `$getLoupeOffsets`: xy = how far to read back (magnification + bevel bend), zw = fringe.
float4 loupeOffsets(float2 rel, LoupeParams L) {
    float d = length(rel);
    if (d >= L.radius || d < 0.001) return float4(0.0);
    float2 base = rel * (1.0 - 1.0 / L.zoom);
    float B = max(L.bevel, 1.0);
    if (d <= L.radius - B) return float4(base, 0.0, 0.0);
    float2 n = rel / d;
    float t = clamp((d - (L.radius - B)) / B, 0.0, 1.0);
    float bend = bevelArcSlope(t) * (1.0 - 1.0 / 1.5) * L.bevel;
    return float4(base + n * bend, n * bend * 0.35 * L.chroma);
}

float loupeOuterShadow(float2 rel, LoupeParams L) {
    if (L.shadowAlpha <= 0.001) return 0.0;
    float S = max(L.shadowSize, 1.0);
    float reach = min(S, L.radius * 0.25);
    float throwBy = min(L.lightTilt * reach, S * 0.45);
    float dd = length(rel + L.light * throwBy);
    float fall = max(S - throwBy, S * 0.4);
    float v = clamp(1.0 - (dd - L.radius) / fall, 0.0, 1.0);
    float side = (dot(rel, L.light) / max(length(rel), 0.001) + 1.0) * 0.5;
    return L.shadowAlpha * mix(1.0, 0.6, side) * v * v;
}

float3 loupePoolLight(float t, float start, float rainbow) {
    float s = clamp((t - start) / (1.0 - start), 0.0, 1.0);
    float prog = pow(s, 0.6);
    float hue = mix(1.0, 0.0, prog) * 2.0 * M_PI_F;
    float sat = smoothstep(0.0, 0.4, s);
    float ch = rainbow * 0.35 * sat;
    float lvl = mix(0.5, 1.0, sat);
    float w = 0.125;
    return float3((1.0 + ch * cos(hue)) * (1.0 + w * 0.878),
                  (1.0 + ch * cos(hue - 2.0943951)) * (1.0 - w * 0.023),
                  (1.0 + ch * cos(hue - 4.1887902)) * (1.0 - w * 0.851)) * lvl;
}

float maxComp(float3 c) { return max(c.r, max(c.g, c.b)); }

float4 composeRelight(float4 c, float shadow, float3 light, float dS, float sS) {
    float3 dif = light * dS, sh = light * sS;
    float3 rgb = c.rgb * ((1.0 - shadow) + dif - sh) + sh;
    rgb /= max(maxComp(rgb), 1.0);
    return float4(rgb, min(c.a + (1.0 - c.a) * shadow + maxComp(sh), 1.0));
}

float shineArc(float width, float edgeK, float spread, float shift, float x) {
    float e0 = 1.0 - width + shift;
    return smoothstep(e0, e0 + max(mix(width, 0.02, edgeK) * (1.0 + spread * 0.5), 0.01), x);
}

/// `$applyLoupeShading`: shadow and caustic pools, then the specular rim.
float4 loupeShade(float4 color, float2 rel, float coverage, float bayer, LoupeParams L) {
    const float3 lamp = float3(1.0, 0.98, 0.95);
    float S = max(L.shadowSize, 1.0), B = max(L.bevel, 1.0);
    float4 out = color;
    float shadow = coverage < 1.0 ? loupeOuterShadow(rel, L) * (1.0 - coverage) : 0.0;
    float3 light = float3(0.0);
    float pk = min(L.bevel * 0.5, 1.0) * L.presence;
    if (pk > 0.001) {
        if (coverage > 0.001) {
            float sz = L.radius;
            float f = clamp((length(rel - L.light * sz) - L.radius) / sz, 0.0, 1.0);
            light += loupePoolLight(f, 0.0, 0.5) * f * f * 0.25 * pk * coverage;
        }
        if (coverage < 1.0) {
            float k = min(L.radius * 0.5, S * 0.45);
            float f = clamp((L.radius - length(rel + L.light * k)) / k, 0.0, 1.0);
            light += loupePoolLight(1.0 - f, 0.0, 0.5) * f * f * 0.3 * pk * (1.0 - coverage);
        }
    }
    if (shadow + light.r + light.g + light.b > 0.0) out = composeRelight(out, shadow, lamp * light, 1.0, 0.35);
    float d = length(rel);
    if (coverage <= 0.0 || d >= L.radius || d < 0.001) return out;
    float pol = pow(3.0, -0.8);
    float band = max(L.radius * 0.036 * pol, 1.0);
    float inner = band * 50.0;
    if (d < L.radius - max(B, inner)) return out;
    float2 n = rel / d;
    float tb = clamp((d - (L.radius - B)) / B, 0.0, 1.0);
    float bk = min(L.bevel * 0.5, 1.0);
    float facing = dot(n, L.light);
    float edge = L.radius - d;
    float bandF = pow(clamp(1.0 - edge / band, 0.0, 1.0), 2.5);
    float s = clamp(1.0 - edge / inner, 0.0, 1.0);
    float innerF = s * s * (3.0 - 2.0 * s) * 0.1;
    float spread = clamp(4.0 / max(L.shineExponent, 1.0), 0.0, 1.0);
    float main = shineArc(0.3, 0.25, spread, 0.0, max(facing, 0.0));
    float opp = 0.28 * shineArc(0.3, 0.25, spread, 0.3 * 0.25, max(-facing, 0.0));
    float imain = shineArc(0.55, 0.125, spread, 0.0, max(facing, 0.0));
    float iopp = 0.28 * shineArc(0.55, 0.125, spread, 0.55 * 0.25, max(-facing, 0.0));
    float diffuse = main * bandF + imain * innerF;
    float sheen = opp * bandF + iopp * innerF;
    float amb = bandF + innerF;
    float str = bk * coverage * L.presence * 1.05;
    float3 rgb = (lamp * diffuse + lamp * float3(0.9, 0.96, 1.05) * sheen + lamp * 0.05 * amb) * str * (1.0 + (bayer - 0.5) * 0.8);
    out.rgb *= 1.0 - 0.14 * tb * tb * bk * coverage;
    if (rgb.r + rgb.g + rgb.b > 0.0) out = composeRelight(out, 0.0, rgb, 0.9, 0.55);
    return out;
}

/// `sampleLoupeView`: lod 0…4 between pre-blurred levels (radius 0.58·(2^lod − 1)).
float4 loupeView(sampler c0, sampler c1, sampler c2, sampler c3, sampler c4, float2 pos, float lod) {
    float4 a = c0.sample(c0.transform(pos));
    if (lod < 0.05) return a;
    float l = clamp(lod, 0.0, 4.0);
    float f = fract(l);
    int i = int(floor(l));
    float4 lo = i == 0 ? a : i == 1 ? c1.sample(c1.transform(pos)) : i == 2 ? c2.sample(c2.transform(pos)) : i == 3 ? c3.sample(c3.transform(pos)) : c4.sample(c4.transform(pos));
    if (f < 0.001 || i >= 4) return lo;
    float4 hi = i == 0 ? c1.sample(c1.transform(pos)) : i == 1 ? c2.sample(c2.transform(pos)) : i == 2 ? c3.sample(c3.transform(pos)) : c4.sample(c4.transform(pos));
    return mix(lo, hi, f);
}

/// `$getBayer8Threshold01` at the output pixel.
float bayer8(float2 px) {
    int x = int(fmod(floor(px.x), 8.0)), y = int(fmod(floor(px.y), 8.0));
    int x0 = x & 1, y0 = y & 1, x1 = (x >> 1) & 1, y1 = (y >> 1) & 1, x2 = (x >> 2) & 1, y2 = (y >> 2) & 1;
    int v = ((((x0 ^ y0)) * 2 + y0) * 16) + ((((x1 ^ y1)) * 2 + y1) * 4) + (((x2 ^ y2)) * 2 + y2);
    return float(v) / 64.0;
}

/// `$ditherColor`: −½…+½ step of 1/255 of screen-Bayer noise, scaled by alpha (anti-banding).
float4 ditherColor(float4 c, float2 px) {
    float noise = (bayer8(px) - 0.5) * (1.0 / 255.0) * c.a;
    return float4(c.rgb + noise, c.a);
}

float spectrumW(float x) { float c = clamp(x, -1.0, 1.0); return c * (1.0 - 2.0 / 3.0 * c * c + c * c * c * c / 5.0); }
float spectrumBand(float s0, float s1, float c0, float w) { return (spectrumW((s1 - c0) / w) - spectrumW((s0 - c0) / w)) * w; }

float bayer4(float2 px) {
    int x = int(fmod(floor(px.x), 4.0)), y = int(fmod(floor(px.y), 4.0));
    const float m[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    return (m[y * 4 + x] + 0.5) / 16.0;
}

float4 loupeGlassShaded(sampler content0, sampler content1, sampler content2, sampler content3, sampler content4, sampler plain, sampler frost,
                  float4 g0, float4 g1, float4 g2, float4 g3, float2 pos);

float4 loupeGlass(sampler content0, sampler content1, sampler content2, sampler content3, sampler content4, sampler plain, sampler frost,
                  float4 g0, float4 g1, float4 g2, float4 g3, destination dest) {
    float2 pos = dest.coord();
    // Every drawn part is dithered against banding (`$ditherColor`).
    return ditherColor(loupeGlassShaded(content0, content1, content2, content3, content4, plain, frost, g0, g1, g2, g3, pos), pos);
}

float4 loupeGlassShaded(sampler content0, sampler content1, sampler content2, sampler content3, sampler content4, sampler plain, sampler frost,
                  float4 g0, float4 g1, float4 g2, float4 g3, float2 pos) {
    LoupeParams L = loupeParams(g0, g1, g2, g3);
    
    float4 scene = plain.sample(plain.transform(pos));
    float aa = 1.5;
    float2 rel = pos - L.center;
    float d = length(rel);
    if (d > L.radius + L.shadowSize + aa) return scene;
    float bayer = bayer4(pos);
    float coverage = clamp((L.radius - d) / aa, 0.0, 1.0);
    if (coverage <= 0.0) return loupeShade(scene, rel, 0.0, bayer, L);

    float4 off = loupeOffsets(rel, L);
    float2 baseInside = (d < L.radius && d >= 0.001) ? rel * (1.0 - 1.0 / L.zoom) : float2(0.0);
    float2 bendPos = pos - (off.xy - baseInside);
    float2 fullPos = pos - off.xy;
    // Read footprint on the compressed rim blurs it (`$getLoupeSampleLodBias`).
    float lodBias = 0.0;
    if (d >= 1.0 && d < L.radius) {
        float2 n = rel / d;
        float2 a = rel - off.xy;
        float2 b = (rel - n) - loupeOffsets(rel - n, L).xy;
        lodBias = clamp(log2(max(length(a - b), 0.01)), -2.0, 4.0);
    }
    float lod = clamp(lodBias + log2(L.zoom), 0.0, 4.0);

    float4 color;
    float2 fr = off.zw;
    float frLen = length(fr);
    if (frLen < 0.75) {
        color = loupeView(content0, content1, content2, content3, content4, bendPos, lod);
    } else {
        int N = int(clamp(ceil(frLen), 3.0, L.maxReads));
        float3 rgb = float3(0.0), wsum = float3(0.0);
        float alpha = 0.0;
        for (int i = 0; i < 16; i++) {
            if (i >= N) break;
            float a = 1.0 - 2.0 * float(i) / float(N);
            float b = a - 2.0 / float(N);
            float s = a - fract(bayer + float(i) * 0.61803398875) * 2.0 / float(N);
            float4 c = loupeView(content0, content1, content2, content3, content4, bendPos + fr * s, lod);
            float3 w = float3(spectrumBand(b, a, 0.85, 0.7) + 0.3 * spectrumBand(b, a, -0.95, 0.35),
                              spectrumBand(b, a, 0.05, 0.65),
                              spectrumBand(b, a, -0.75, 0.65));
            rgb += c.rgb * w; wsum += w; alpha += c.a;
        }
        color = float4(rgb / max(wsum, float3(0.0001)), alpha / float(N));
    }
    if (color.a < 1.0) color = color + frost.sample(frost.transform(fullPos)) * (1.0 - color.a);

    // Fresnel rim reflection of the stage just outside the lens (`$getLoupeRimReflection`).
    float k = min(L.bevel * 0.5, 1.0) * L.presence;
    if (k > 0.001 && d < L.radius && d >= 0.001) {
        float band = max(min(L.bevel * 1.5, L.radius), 1.0);
        if (d > L.radius - band) {
            float t = clamp((d - (L.radius - band)) / band, 0.0, 1.0);
            float slope = bevelArcSlope(t);
            float cosI = rsqrt(1.0 + slope * slope);
            float weight = clamp((0.04 + 0.96 * pow(1.0 - cosI, 5.0)) * smoothstep(1.0, 1.5, slope) * k, 0.0, 1.0);
            if (weight > 0.004) {
                float hover = L.radius * 0.25;
                float dist = max(d + min(2.0 * hover * slope / max(slope * slope - 1.0, 0.05), L.radius), L.radius + 1.0);
                float2 sp = L.center + rel / d * dist;
                float4 s = plain.sample(plain.transform(sp));
                color = mix(color, float4(s.rgb * (1.0 - loupeOuterShadow(sp - L.center, L)), s.a), weight);
            }
        }
    }
    if (coverage >= 1.0) return loupeShade(color, rel, 1.0, bayer, L);
    return loupeShade(mix(scene, color, coverage), rel, coverage, bayer, L);
}


// MARK: Camera film grain

float3 hashGrainCell(float x, float y, float seed) {
    float3 h = fract(float3(x, y, seed) * float3(0.1031, 0.103, 0.0973));
    h = h + dot(h, h.yxz + 33.33);
    return fract((h.xxy + h.yxx) * h.zyx) * 2.0 - 1.0;
}

float3 grainLatticeNoise(float2 coords, float seed) {
    float2 cell = floor(coords);
    float2 f = coords - cell;
    float2 e = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float3 c00 = hashGrainCell(cell.x, cell.y, seed);
    float3 c10 = hashGrainCell(cell.x + 1.0, cell.y, seed);
    float3 c01 = hashGrainCell(cell.x, cell.y + 1.0, seed);
    float3 c11 = hashGrainCell(cell.x + 1.0, cell.y + 1.0, seed);
    return mix(mix(c00, c10, e.x), mix(c01, c11, e.x), e.y);
}

/// Grain on the camera layer: value noise of 1.1 px cells plus 1.7× coarser cells, 65% mono,
/// strongest in midtones, added to the sqrt-encoded colour.
float4 filmGrain(sample_t c, float4 params, destination dest) {
    float intensity = params.x, seed = params.y;
    if (intensity < 0.001 || c.a < 0.001) return c;
    float3 s = sqrt(max(c.rgb / c.a, float3(0.0)));
    float2 texel = dest.coord();
    float2 fine = texel * (1.0 / 1.1);
    float2 coarse = fine * (1.0 / 1.7) + 511.5;
    float3 noise = (grainLatticeNoise(fine, seed) * 0.65 + grainLatticeNoise(coarse, seed + 1024.0) * 0.35) * 3.0;
    float3 grain = mix(float3(noise.y), noise, 0.35);
    float luma = clamp(dot(s, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    float response = smoothstep(0.0, 0.1, luma) * (1.0 - 0.65 * smoothstep(0.55, 1.0, luma));
    s = clamp(s + grain * intensity * 0.09 * response, float3(0.0), float3(1.0));
    return float4(s * s * c.a, c.a);
}


/// `$ditherColor` on a whole layer (screen and camera parts, gradient backgrounds).
float4 antiBandingDither(sample_t c, destination dest) {
    return ditherColor(c, dest.coord());
}

// MARK: - Privacy auto-masks

/// One colour per quadrant of each text cover (64×2: slot·2 + column, row; row 0 is the
/// bottom half): a robust mean of a ring just outside the corner's two half-edges
/// (16 samples each, at 1 and 2 ring distances), mixed 30 % with a 4×4 grid inside.
float4 autoMaskColors(sampler src, sampler boxes, float count, destination dest) {
    float2 d = dest.coord();
    float slot = floor(d.x / 2.0);
    if (slot >= count) return float4(0.0);
    float qx = fmod(floor(d.x), 2.0);
    float qy = floor(d.y);
    float4 box = boxes.sample(boxes.transform(float2(slot + 0.5, 0.5)));
    float2 origin = box.xy;
    float2 size = box.zw;
    float ring = clamp(size.y * 0.12, 1.5, 5.0);
    // The quadrant's corner, and the half-edges leaving it.
    float2 corner = origin + float2(qx, qy) * size;
    float2 alongX = float2(qx > 0.5 ? -1.0 : 1.0, 0.0) * size.x * 0.5;
    float2 alongY = float2(0.0, qy > 0.5 ? -1.0 : 1.0) * size.y * 0.5;
    float2 outX = float2(qx > 0.5 ? 1.0 : -1.0, 0.0);
    float2 outY = float2(0.0, qy > 0.5 ? 1.0 : -1.0);
    float3 samples[64];
    float3 mean = float3(0.0);
    int n = 0;
    for (int depth = 1; depth <= 2; depth++) {
        for (int i = 0; i < 16; i++) {
            float t = (float(i) + 0.5) / 16.0;
            float2 a = corner + alongX * t + outY * ring * float(depth);
            float2 b = corner + alongY * t + outX * ring * float(depth);
            samples[n] = src.sample(src.transform(a)).rgb; mean += samples[n]; n++;
            samples[n] = src.sample(src.transform(b)).rgb; mean += samples[n]; n++;
        }
    }
    mean /= 64.0;
    float3 weighted = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < 64; i++) {
        float3 c = samples[i] - mean;
        float w = exp(-dot(c, c) / (0.12 * 0.12));
        weighted += samples[i] * w;
        total += w;
    }
    float3 ringColor = total > 0.0 ? weighted / total : mean;
    float3 inside = float3(0.0);
    float2 quadOrigin = origin + float2(qx, qy) * size * 0.5;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            float2 p = quadOrigin + (float2(x, y) + 0.5) / 4.0 * size * 0.5;
            inside += src.sample(src.transform(p)).rgb;
        }
    }
    inside /= 16.0;
    return float4(mix(ringColor, inside, 0.3), 1.0);
}

/// Text covers (rounded rects, radius min(w,h)/4, filled with their quadrant colours, a 5 %
/// inner shadow) then face covers (circles of radius 0.65·max(w,h) over the blurred footage).
/// …31 text, 32…47 faces, each (x, y, w, h) in pixels, bottom-left origin.
float4 autoMaskApply(sampler src, sampler blurred, sampler boxes, sampler colors, float textCount, float faceCount, destination dest) {
    float2 p = dest.coord();
    float4 out = src.sample(src.transform(p));
    float aa = 0.75;
    for (int i = 0; i < 32; i++) {
        if (float(i) >= textCount) break;
        float4 box = boxes.sample(boxes.transform(float2(float(i) + 0.5, 0.5)));
        float2 halfSize = box.zw * 0.5;
        float2 c = box.xy + halfSize;
        float r = min(halfSize.x, halfSize.y) * 0.5;
        float2 q = abs(p - c) - (halfSize - r);
        float sd = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
        float coverage = 1.0 - smoothstep(-aa, aa, sd);
        if (coverage <= 0.0) continue;
        float2 uv = clamp((p - box.xy) / max(box.zw, float2(1.0)), 0.0, 1.0);
        float4 fill = colors.sample(colors.transform(float2(float(i) * 2.0 + 0.5 + uv.x, 0.5 + uv.y)));
        float reach = max(min(box.z, box.w) * 0.5, 1.0);
        float shade = 0.05 * (1.0 - smoothstep(0.0, 1.0, clamp(-sd / reach, 0.0, 1.0)));
        fill.rgb -= shade * fill.rgb;
        out = mix(out, float4(fill.rgb, 1.0), coverage);
    }
    for (int i = 0; i < 16; i++) {
        if (float(i) >= faceCount) break;
        float4 box = boxes.sample(boxes.transform(float2(32.0 + float(i) + 0.5, 0.5)));
        float2 c = box.xy + box.zw * 0.5;
        float r = max(box.z, box.w) * 0.65;
        float coverage = 1.0 - smoothstep(-aa, aa, length(p - c) - r);
        if (coverage <= 0.0) continue;
        out = mix(out, blurred.sample(blurred.transform(p)), coverage);
    }
    return out;
}

// MARK: Click effects
// Drawn into the recording itself; lengths are pixels of that image. Up to three clicks:
// point = (centre, 0, live), state = (radius, fade or bounce, 0, 0), knobs = (pull size, 0, 0, 0),
// params = (mode 1 ripple / 2 circle, video width, antialias width, most reads),
// output = (x scale, x offset, y scale, y offset) to top-left output pixels.

/// `$offsets` of one ripple: xy = how far back to read (the pull), zw = the colour split.
float4 clickRippleOffsets(float2 pixel, float4 point, float4 state, float4 knobs, float videoWidth) {
    if (point.w <= 0.0) return float4(0.0);
    float bounce = state.y;
    if (bounce == 0.0) return float4(0.0);
    float2 relative = pixel - point.xy;
    float distance = length(relative);
    float radius = state.x;
    float band = videoWidth * 0.05;
    if (abs(distance - radius) > band * 3.0) return float4(0.0);
    float ringDistance = (distance - radius) / band;
    float ring = exp(-ringDistance * ringDistance * 4.0);
    if (distance == 0.0) return float4(0.0);
    float pullSize = knobs.x;
    float calmZoneFade = 1.0;
    if (pullSize > 0.5) calmZoneFade = smoothstep(pullSize * 0.35, pullSize, distance);
    float2 direction = relative * (1.0 / distance);
    float2 pull = direction * (bounce * ring * videoWidth * 0.015 * calmZoneFade);
    float2 split = direction * (abs(bounce) * ring * (1.0 - ring) * 4.0 * videoWidth * 0.004 * calmZoneFade);
    return float4(pull, split);
}

float4 clickRipplesOffsets(float2 pixel, float4 p0, float4 p1, float4 p2, float4 s0, float4 s1, float4 s2, float4 knobs, float videoWidth) {
    return clickRippleOffsets(pixel, p0, s0, knobs, videoWidth)
        + clickRippleOffsets(pixel, p1, s1, knobs, videoWidth)
        + clickRippleOffsets(pixel, p2, s2, knobs, videoWidth);
}

/// `$overlay` of one circle: a light grey disc with a thin dark rim, over `color`.
float4 clickCircleOverlay(float4 color, float2 pixel, float4 point, float4 state, float videoWidth, float antialiasWidth) {
    if (point.w <= 0.0) return color;
    float fade = state.y;
    if (fade <= 0.0) return color;
    float radius = state.x;
    float distance = length(pixel - point.xy);
    if (distance > radius + antialiasWidth) return color;
    float fill = 1.0 - smoothstep(radius - antialiasWidth, radius + antialiasWidth, distance);
    float rimWidth = videoWidth * 0.0007;
    float rim = 1.0 - smoothstep(rimWidth, rimWidth + antialiasWidth, abs(distance - radius));
    float3 fillColor = float3(0.87 * 0.87);
    float3 rimColor = float3(0.0);
    float rimAlpha = rim * 0.5;
    float shapeAlpha = rimAlpha + fill * (1.0 - rimAlpha);
    float3 shapeColor = rimColor * rimAlpha + fillColor * (fill * (1.0 - rimAlpha));
    float4 circle = float4(shapeColor * (0.6 * fade), shapeAlpha * 0.6 * fade);
    return color * (1.0 - circle.w) + circle;
}

/// `$getInterleavedGradientNoise01` at an output pixel.
float interleavedGradientNoise(float2 px) {
    float x = floor(px.x), y = floor(px.y);
    return fract(52.9829189 * fract(0.06711056 * x + 0.00583715 * y));
}

float4 clickEffects(sampler image, float4 p0, float4 p1, float4 p2, float4 s0, float4 s1, float4 s2, float4 knobs, float4 params, float4 output, destination dest) {
    float2 pos = dest.coord();
    float mode = params.x;
    float videoWidth = params.y;
    float antialiasWidth = params.z;
    if (mode == 2.0) {
        float4 color = image.sample(image.transform(pos));
        color = clickCircleOverlay(color, pos, p0, s0, videoWidth, antialiasWidth);
        color = clickCircleOverlay(color, pos, p1, s1, videoWidth, antialiasWidth);
        return clickCircleOverlay(color, pos, p2, s2, videoWidth, antialiasWidth);
    }
    // The ripple pulls the read position, then splits colours where it is read.
    float2 readPixel = pos - clickRipplesOffsets(pos, p0, p1, p2, s0, s1, s2, knobs, videoWidth).xy;
    float2 split = clickRipplesOffsets(readPixel, p0, p1, p2, s0, s1, s2, knobs, videoWidth).zw;
    if (dot(split, split) < 0.01 * 0.01) return image.sample(image.transform(readPixel));
    float jitter = interleavedGradientNoise(float2(pos.x * output.x + output.y, pos.y * output.z + output.w));
    int reads = int(clamp(ceil(length(split) * 2.0), 3.0, params.w));
    float segment = 2.0 / float(reads);
    float3 color = float3(0.0), colorWeight = float3(0.0);
    float alpha = 0.0;
    for (int i = 0; i < 32; i++) {
        if (i >= reads) break;
        float bandEnd = 1.0 - float(i) * segment;
        float strataJitter = fract(jitter + float(i) * 0.61803398875);
        float s = bandEnd - strataJitter * segment;
        float4 c = image.sample(image.transform(readPixel + split * s));
        float b = bandEnd - segment;
        float3 weight = float3(spectrumBand(b, bandEnd, 0.85, 0.7) + 0.3 * spectrumBand(b, bandEnd, -0.95, 0.35),
                               spectrumBand(b, bandEnd, 0.05, 0.65),
                               spectrumBand(b, bandEnd, -0.75, 0.65));
        color += c.rgb * weight;
        colorWeight += weight;
        alpha += c.a;
    }
    return float4(color / colorWeight, alpha / float(reads));
}

// MARK: - Backgrounds and deband

/// sRGB-encoded channel to linear and back (`$linearChannelFromSrgb`, `$srgbChannelFromLinear`).
float srgbToLinear(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
float linearToSrgb(float c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055; }

/// OKLCH (lightness, chroma, hue radians) to encoded sRGB, the linear values clamped to 0…1.
float3 srgbFromOklch(float3 lch) {
    float3 lab = float3(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z));
    float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s = lab.x - 0.0894841775 * lab.y - 1.291485548 * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    float3 rgb = float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                        -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s);
    rgb = clamp(rgb, float3(0.0), float3(1.0));
    return float3(linearToSrgb(rgb.x), linearToSrgb(rgb.y), linearToSrgb(rgb.z));
}

/// `source/gradient`: the colour along the line from `line.xy` to `line.zw` (uv, top-left),
/// mixed stop to stop in OKLCH, premultiplied, dithered at the texel. Encoded sRGB out.
/// `size` = (width, height, stopCount, -); offsets in o0, o1; stops (L, C, h, alpha) c0…c7.
float4 oklchGradient(float4 line, float4 size, float4 o0, float4 o1,
                     float4 c0, float4 c1, float4 c2, float4 c3, float4 c4, float4 c5, float4 c6, float4 c7,
                     destination dest) {
    float2 coord = dest.coord();
    float2 uv = float2(coord.x / size.x, 1.0 - coord.y / size.y);
    float2 lineVector = line.zw - line.xy;
    float lengthSquared = max(dot(lineVector, lineVector), 0.000001);
    float t = clamp(dot(uv - line.xy, lineVector) / lengthSquared, 0.0, 1.0);
    float offsets[8] = { o0.x, o0.y, o0.z, o0.w, o1.x, o1.y, o1.z, o1.w };
    float4 stops[8] = { c0, c1, c2, c3, c4, c5, c6, c7 };
    float4 color = stops[0];
    for (int i = 1; i < 8; i++) {
        float span = max(offsets[i] - offsets[i - 1], 0.000001);
        float segment = clamp((t - offsets[i - 1]) / span, 0.0, 1.0);
        float active = float(i) < size.z ? 1.0 : 0.0;
        color = mix(color, stops[i], segment * active);
    }
    float3 srgb = srgbFromOklch(color.xyz);
    return ditherColor(float4(srgb * color.w, color.w), float2(coord.x, size.y - coord.y));
}

}
}
