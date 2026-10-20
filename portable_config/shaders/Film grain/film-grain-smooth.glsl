//!HOOK LUMA
//!BIND HOOKED
//!DESC film grain smooth v2 (gaussian, race-free, variance-corrected)
//!COMPUTE 32 32

// Coarse (low-pass) grain. Use this only when you actually want a clumpy
// film look, or when per-pixel grain is too fine to survive your display.
// For masking compression artifacts, the fine version is better.
//
// Fixed vs. the original:
//   * the horizontal pass wrote back into the array it was still reading
//     from, with no barrier -> data race -> blotchy 32x32 tile structure
//   * seed indexing transposed x/y
//   * blurring destroys ~65% of the grain's RMS; now restored, so INTENSITY
//     means the same thing here as in the fine shader
//   * float-hash precision loss at high resolutions

// ---------------------------------------------------------------- tunables
#define INTENSITY        0.045
#define TAPS             2      // grain radius: 1 = tight, 5 = very clumpy
#define SHADOW_CUTOFF    0.04
#define SHADOW_KNEE      0.18
#define HIGHLIGHT_KNEE   0.80
#define HIGHLIGHT_CUTOFF 1.00
#define TEMPORAL_DIV     1      // 1 = every frame, 2 = every 2nd, 0 = static
#define CLAMP_OUTPUT     1
// ---------------------------------------------------------------------------

const uint row_size = 2 * TAPS + 1;
const float weights[row_size] = {
#if TAPS == 1
    0.10650697891920,
    0.78698604216159,
    0.10650697891920,
#endif

#if TAPS == 2
    0.05448868454964,
    0.24420134200323,
    0.40261994689424,
    0.24420134200323,
    0.05448868454964,
#endif

#if TAPS == 3
    0.03663284536919,
    0.11128075847888,
    0.21674532140370,
    0.27068214949642,
    0.21674532140370,
    0.11128075847888,
    0.03663284536919,
#endif

#if TAPS == 4
    0.02763055063889,
    0.06628224528636,
    0.12383153680577,
    0.18017382291138,
    0.20416368871516,
    0.18017382291138,
    0.12383153680577,
    0.06628224528636,
    0.02763055063889,
#endif

#if TAPS == 5
    0.02219054849244,
    0.04558899978527,
    0.07981140824009,
    0.11906462996609,
    0.15136080967773,
    0.16396720767670,
    0.15136080967773,
    0.11906462996609,
    0.07981140824009,
    0.04558899978527,
    0.02219054849244,
#endif
};

const uvec2 isize = uvec2(gl_WorkGroupSize) + uvec2(2 * TAPS);

shared float grain[isize.y][isize.x];             // raw noise + apron
shared float tmp[isize.y][gl_WorkGroupSize.x];    // horizontally filtered

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

// Seeded from global pixel coordinates, so tile aprons match their neighbours
// exactly and no seam appears at workgroup borders.
float grain_at(ivec2 pos, uint t)
{
    return to_gaussian(float(hash3(uvec3(uvec2(pos + 32768), t))) * (1.0 / 4294967296.0));
}

void hook()
{
#if TEMPORAL_DIV > 0
    uint t = uint(max(frame, 0)) / uint(TEMPORAL_DIV);
#else
    uint t = 0u;
#endif

    uint num_threads = gl_WorkGroupSize.x * gl_WorkGroupSize.y;
    ivec2 base = ivec2(gl_WorkGroupID.xy * gl_WorkGroupSize.xy) - ivec2(TAPS);

    for (uint i = gl_LocalInvocationIndex; i < isize.x * isize.y; i += num_threads) {
        uvec2 p = uvec2(i % isize.x, i / isize.x);
        grain[p.y][p.x] = grain_at(base + ivec2(p), t);
    }

    barrier();

    // horizontal pass -> separate buffer (no in-place read/write race)
    for (uint y = gl_LocalInvocationID.y; y < isize.y; y += gl_WorkGroupSize.y) {
        float hsum = 0.0;
        for (uint x = 0; x < row_size; x++)
            hsum += weights[x] * grain[y][gl_LocalInvocationID.x + x];
        tmp[y][gl_LocalInvocationID.x] = hsum;
    }

    barrier();

    float vsum = 0.0;
    for (uint y = 0; y < row_size; y++)
        vsum += weights[y] * tmp[gl_LocalInvocationID.y + y][gl_LocalInvocationID.x];

    // Blurring N independent gaussians scales sigma by sqrt(sum(w^2)) per
    // axis, i.e. sum(w^2) separably in 2D. Divide it back out to keep the
    // grain as strong as the unsmoothed version.
    float wss = 0.0;
    for (uint i = 0; i < row_size; i++)
        wss += weights[i] * weights[i];
    vsum /= wss;

    vec4 color = HOOKED_tex(HOOKED_pos);

    float l = clamp(color.x, 0.0, 1.0);
    float w = smoothstep(SHADOW_CUTOFF, SHADOW_KNEE, l)
            * (1.0 - smoothstep(HIGHLIGHT_KNEE, HIGHLIGHT_CUTOFF, l));

    color.x += INTENSITY * w * vsum;
#if CLAMP_OUTPUT
    color.x = clamp(color.x, 0.0, 1.0);
#endif
    imageStore(out_image, ivec2(gl_GlobalInvocationID), color);
}
