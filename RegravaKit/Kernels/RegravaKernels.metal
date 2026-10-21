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

}
}
