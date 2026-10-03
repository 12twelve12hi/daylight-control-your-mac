// Daylight compositor shaders (SPEC 6.6, research-mac-pipeline 3.2). One render pass, bgra8Unorm everywhere
// (non-sRGB so the webcam and the SolOS token colours pass through byte-exact).
#include <metal_stdlib>
using namespace metal;

struct QuadVertex {
    float2 position;   // clip space
    float2 uv;         // v = 0 is the top row
};

struct RasterData {
    float4 position [[position]];
    float2 uv;
};

vertex RasterData daylight_vertex(uint vid [[vertex_id]], const device QuadVertex *vertices [[buffer(0)]]) {
    RasterData out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.uv = vertices[vid].uv;
    return out;
}

/// The presenter crop and the mirror picture: one texture read, opaque output.
fragment float4 daylight_textured(RasterData in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);
    return float4(c.rgb, 1.0);
}

/// Paper, highlighter multiplied under the ink (both layers premultiplied BGRA):
/// under = paper * ((1 - hl.a) + hl.rgb); out = ink.rgb + (1 - ink.a) * under; alpha = 1.
fragment float4 daylight_canvas(RasterData in [[stage_in]],
                                texture2d<float> ink [[texture(0)]],
                                texture2d<float> highlight [[texture(1)]],
                                constant float4 &paper [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 hl = highlight.sample(s, in.uv);
    float3 under = paper.rgb * ((1.0 - hl.a) + hl.rgb);
    float4 i = ink.sample(s, in.uv);
    return float4(i.rgb + (1.0 - i.a) * under, 1.0);
}

/// Cream panel, border lines and the divider (alpha blended so the divider can fade with the slide).
fragment float4 daylight_solid(RasterData in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return color;
}
