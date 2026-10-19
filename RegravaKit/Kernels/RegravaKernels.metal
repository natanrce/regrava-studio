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

}
}
