#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// `fillUnder`: 1 device px of anti-aliasing at the top, fading from 50 % at the bottom to
// 100 % at the column's own top.
static float fillUnder(float h, float fromBottom, float scale) {
    float coverage = clamp((h - fromBottom) * scale + 0.5, 0.0, 1.0);
    return coverage * mix(0.5, 1.0, clamp(fromBottom / max(h, 1.0), 0.0, 1.0));
}

// The `timeline/slice-waveform` fragment for one clip's visible part. `columns` holds, per device
// pixel column and layer, the shape height and the full-volume ghost height (0 = none), in
// points; `layers` holds each layer's sRGB colour and opacity.
[[ stitchable ]] half4 sliceWaveform(float2 position, half4 color, device const float *columns, int columnCount,
                                     device const float *layers, int layerFloats, float scale, float height) {
    int layerCount = layerFloats / 4;
    if (layerCount == 0) return half4(0);
    int column = clamp(int(position.x * scale), 0, columnCount / (layerCount * 2) - 1);
    float fromBottom = height - position.y;
    float4 out = float4(0);
    for (int l = 0; l < layerCount; l++) {
        int i = (column * layerCount + l) * 2;
        float shape = layers[l * 4 + 3] * fillUnder(columns[i], fromBottom, scale);
        float ghost = columns[i + 1] > 0 ? 0.1 * fillUnder(columns[i + 1], fromBottom, scale) : 0.0;
        float alpha = shape + ghost * (1.0 - shape);
        float3 rgb = float3(layers[l * 4], layers[l * 4 + 1], layers[l * 4 + 2]);
        out = float4(rgb * alpha, alpha) + out * (1.0 - alpha);
    }
    return half4(out);
}
