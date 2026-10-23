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
    return (float(v) + 0.5) / 64.0;
}

/// `$ditherColor`: ±half a step of 1/255 of screen-Bayer noise, scaled by alpha (anti-banding).
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

}
}
