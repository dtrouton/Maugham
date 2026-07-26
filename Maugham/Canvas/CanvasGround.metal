#include <metal_stdlib>
using namespace metal;

// Seeded value noise. Generated per-pixel in CONTENT space, not screen space:
// a shader using bare `position` makes the grain crawl across the paper as you
// pan (spec §7A.4).
static float hash21(float2 p) {
    // SplitMix-flavoured integer hash. Deliberately not `fract(sin(...))`,
    // which bands badly on Apple GPUs at low amplitude.
    uint2 q = uint2(int2(floor(p))) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    n = (n ^ (n >> 15)) * 2246822519u;
    n = (n ^ (n >> 13)) * 3266489917u;
    return float(n ^ (n >> 16)) / 4294967295.0;
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// A `colorEffect` shader: SwiftUI supplies `position` (this view's local
// coordinate space) and `currentColor` (the pixel already painted — here the
// appearance-resolved base colour). Everything after those is a uniform we pass.
//
// pan/zoom arrive as uniforms so the grain is sampled in CONTENT space and
// stays put under the writer's hand.
[[ stitchable ]]
half4 canvasGround(float2 position,
                   half4 currentColor,
                   float2 pan,
                   float zoom,
                   float grainScale) {
    float2 content = (position - pan) / max(zoom, 0.0001);

    // Fade grain amplitude as a function of zoom to kill moire on zoom-out.
    // Analytically fwidth(content) == 1.0/zoom, so no derivative functions are
    // needed (spec §7A.4).
    float amplitude = 0.055 * smoothstep(0.25, 1.0, zoom);

    float n = valueNoise(content * grainScale) - 0.5;
    half3 rgb = currentColor.rgb + half3(half(n * amplitude));

    // Light falls from one corner (§7.1). Light ages better than texture.
    float2 lit = content * 0.0004;
    half fall = half(clamp(1.0 - 0.10 * length(lit - float2(-0.35, -0.35)), 0.86, 1.0));

    return half4(rgb * fall, currentColor.a);
}
