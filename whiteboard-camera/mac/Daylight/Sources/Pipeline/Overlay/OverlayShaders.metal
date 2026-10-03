// Presenter Overlay shaders (SPEC 6.7). A separate translation unit from Shaders.metal: RasterData is redeclared here
// with the identical layout so `daylight_overlay` pairs with the shared `daylight_vertex` from the same library.
#include <metal_stdlib>
using namespace metal;

struct RasterData {
    float4 position [[position]];
    float2 uv;
};

/// Matches `Compositor.OverlayUniforms` in Swift: a float4 then four floats, 32 bytes.
struct OverlayUniforms {
    float4 haloColor;     // rgb used, a ignored
    float maskStrength;   // 0 plain rectangle, 1 full matte
    float opacity;        // cutout opacity at this progress
    float haloRadius;     // in mask texels
    float haloEnabled;    // 0 or 1
};

/// The presenter cutout. The mask covers the whole camera frame, so it is sampled at the presenter's uv.
/// alpha = mix(1, m, maskStrength) * opacity. With the halo on, a ring of 8 taps at `haloRadius` mask texels gives the
/// dilated mask; halo = saturate(dilated - m) * maskStrength * opacity is the amber band just outside the person.
/// The presenter is composited over the halo ("over" operator), and the result is straight alpha for the
/// sourceAlpha / oneMinusSourceAlpha blend state. At maskStrength 0 and opacity 1 the output is the presenter, opaque.
fragment float4 daylight_overlay(RasterData in [[stage_in]],
                                 texture2d<float> presenter [[texture(0)]],
                                 texture2d<float> mask [[texture(1)]],
                                 constant OverlayUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 rgb = presenter.sample(s, in.uv).rgb;
    float m = mask.sample(s, in.uv).r;
    float alpha = mix(1.0, m, u.maskStrength) * u.opacity;
    float halo = 0.0;
    if (u.haloEnabled > 0.5 && u.maskStrength > 0.0) {
        float2 texelStep = u.haloRadius / float2(float(mask.get_width()), float(mask.get_height()));
        float dilated = m;
        for (int i = 0; i < 8; i++) {
            float angle = float(i) * (M_PI_F / 4.0);
            dilated = max(dilated, mask.sample(s, in.uv + float2(cos(angle), sin(angle)) * texelStep).r);
        }
        halo = saturate(dilated - m) * u.maskStrength * u.opacity;
    }
    float outAlpha = alpha + halo * (1.0 - alpha);
    float3 colour = rgb;
    if (outAlpha > 0.0001) {
        colour = (rgb * alpha + u.haloColor.rgb * halo * (1.0 - alpha)) / outAlpha;
    }
    return float4(colour, outAlpha);
}

/// Temporal smoothing of the person mask: out = k * previous + (1 - k) * current (OverlayLayout.smoothed).
kernel void daylight_mask_iir(texture2d<float, access::read> current [[texture(0)]],
                              texture2d<float, access::read> previous [[texture(1)]],
                              texture2d<float, access::write> out [[texture(2)]],
                              constant float &k [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) {
        return;
    }
    float n = current.read(gid).r;
    float p = previous.read(gid).r;
    out.write(float4(k * p + (1.0 - k) * n, 0.0, 0.0, 1.0), gid);
}

/// One direction of the separable feather blur. `params.x` is the radius, `params.y` the direction (0 horizontal,
/// 1 vertical); `weights` holds 2 * radius + 1 taps (OverlayLayout.featherWeights). Edge texels are clamped.
kernel void daylight_mask_blur(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant float *weights [[buffer(0)]],
                               constant int2 &params [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int w = int(dst.get_width());
    int h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) {
        return;
    }
    int r = params.x;
    int2 dir = params.y == 0 ? int2(1, 0) : int2(0, 1);
    float sum = 0.0;
    for (int i = -r; i <= r; i++) {
        int2 p = clamp(int2(gid) + dir * i, int2(0, 0), int2(w - 1, h - 1));
        sum += weights[i + r] * src.read(uint2(p)).r;
    }
    dst.write(float4(sum, 0.0, 0.0, 1.0), gid);
}
