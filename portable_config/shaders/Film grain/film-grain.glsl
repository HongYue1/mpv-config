//!HOOK LUMA
//!BIND HOOKED
//!DESC film grain v2 (gaussian, luma-weighted)

// Fine per-pixel gaussian grain. Good for masking banding / blocking /
// mosquito noise in low-bitrate video, and for giving a sharpener something
// other than compression artifacts to bite into.
//
// If grain looks smeared on a 4K screen with 1080p sources, the scaler is
// resampling it: copy this file, change the HOOK directive on line 1 from
// LUMA to OUTPUT, and run it after your upscaler + sharpener instead.

// ---------------------------------------------------------------- tunables
#define INTENSITY        0.045  // peak amplitude: 0.02 subtle, 0.08 heavy
#define GRAIN_SIZE       1.0    // 1.0 = per pixel, 1.5-2.5 = coarser/filmic
#define SHADOW_CUTOFF    0.04   // no grain below this luma (keeps blacks clean)
#define SHADOW_KNEE      0.18   // full grain above this luma
#define HIGHLIGHT_KNEE   0.80   // grain starts fading above this luma
#define HIGHLIGHT_CUTOFF 1.00   // no grain at/above this luma
#define TEMPORAL_DIV     1      // 1 = new grain each frame, 2 = every 2nd, 0 = static
#define CLAMP_OUTPUT     1      // set 0 for HDR / float pipelines
// ---------------------------------------------------------------------------

// Integer hash (PCG-style). Replaces the float permute chain: no precision
// falloff at high resolutions, no visible lattice structure, same cost.
uint hash3(uvec3 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v.x;
}

float to_unorm(uint h)
{
    return float(h) * (1.0 / 4294967296.0);
}

// Uniform -> gaussian via an approximation of the gaussian quantile function.
// Output is normalized to [-1,1), so INTENSITY keeps its usual meaning.
float to_gaussian(float u)
{
    const float a0 =  0.151015505647689;
    const float a1 = -0.5303572634357367;
    const float a2 =  1.365020122861334;
    const float b0 =  0.132089632343748;
    const float b1 = -0.7607324991323768;

    float p = 0.95 * u + 0.025;
    float q = p - 0.5;
    float r = q * q;

    return q * (a2 + (a1 * r + a0) / (r * r + b1 * r + b0)) * 0.255121822830526;
}

float grain_at(ivec2 cell, uint t)
{
    return to_gaussian(to_unorm(hash3(uvec3(uvec2(cell + 32768), t))));
}

vec4 hook()
{
#if TEMPORAL_DIV > 0
    uint t = uint(max(frame, 0)) / uint(TEMPORAL_DIV);
#else
    uint t = 0u;
#endif

    // Grain lattice. The -0.5 makes GRAIN_SIZE == 1.0 land exactly on one
    // cell per pixel (no accidental self-blurring at the default setting).
    vec2  gp = HOOKED_pos * HOOKED_size / GRAIN_SIZE - 0.5;
    ivec2 c  = ivec2(floor(gp));
    vec2  f  = fract(gp);

    vec2 w1 = f * f * (3.0 - 2.0 * f);   // smoothstep weights
    vec2 w0 = 1.0 - w1;

    float g = w0.x * w0.y * grain_at(c + ivec2(0, 0), t)
            + w1.x * w0.y * grain_at(c + ivec2(1, 0), t)
            + w0.x * w1.y * grain_at(c + ivec2(0, 1), t)
            + w1.x * w1.y * grain_at(c + ivec2(1, 1), t);

    // Interpolating independent gaussians lowers their variance; undo that so
    // coarse grain is as strong as fine grain instead of washing out.
    float ss = (w0.x * w0.x + w1.x * w1.x) * (w0.y * w0.y + w1.y * w1.y);
    g *= inversesqrt(max(ss, 1e-6));

    vec4 color = HOOKED_tex(HOOKED_pos);

    // Film responds least in the toe and shoulder. Flat grain crushes black
    // level and sparkles in specular highlights, which a sharpener then eats.
    float l = clamp(color.x, 0.0, 1.0);
    float w = smoothstep(SHADOW_CUTOFF, SHADOW_KNEE, l)
            * (1.0 - smoothstep(HIGHLIGHT_KNEE, HIGHLIGHT_CUTOFF, l));

    color.x += INTENSITY * w * g;
#if CLAMP_OUTPUT
    color.x = clamp(color.x, 0.0, 1.0);
#endif
    return color;
}
