// film-grain-smooth.glsl - coarse (low-pass) film grain for mpv, v3.1
//
// Gaussian-blurred grain: a clumpier film look, or grain that survives a display where
// per-pixel grain is too fine to see. For masking compression artifacts the fine version
// (film-grain.glsl) is better. Parameters mean the same as there; taps replaces grain_size.
//
// Where it runs: like film-grain.glsl - the luma plane of YUV video, or the RGB plane of RGB
// sources. For grain at screen resolution, replace the two HOOK directive lines below with one
// HOOK directive naming OUTPUT; the code detects the stage.
//
// Use vo=gpu-next (mpv's default). With vo=gpu, mpv 0.41.0 rejects PARAM blocks and does not
// load this file; the nightly tested (v0.41.0-1288) accepts it. Needs compute shader support in
// the GPU API. Work groups are 16x8 = 128 threads: the minimum that every Vulkan and GLES 3.1
// device must support.
//
// Changes from v2: 128 instead of 1024 threads per work group (1024 is above that guaranteed
// minimum; on a GPU with a lower limit, libplacebo fails the pass); no {} array initialisers or implicit
// int/uint conversions (not portable GLSL); blur kernel computed from taps (identical to v2's
// table) with a compile-time range check; no stores outside the image in the edge blocks;
// timestamp seeding, RGB support and range handling as in film-grain.glsl.
//
// Changes from v3 (same as film-grain.glsl v3.1): steady grain_rate cadence with timestamps
// rounded to the millisecond (Matroska); no grain residue on 10-bit limited-range white;
// intensity=0 skips the pass completely.
//
// Tuning without editing the file, in mpv.conf:
//   glsl-shader-opts=film-grain-smooth/intensity=0.07,film-grain-smooth/taps=3
// "film-grain-smooth" is this file's name without ".glsl". Without a prefix, a value applies to
// every loaded shader with a parameter of that name (e.g. both grain shaders).

//!PARAM intensity
//!DESC grain strength in display units (0-1 RGB): RMS = 0.22 x intensity. 0.025 subtle, 0.09 heavy
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.052

//!PARAM taps
//!DESC grain radius in pixels (gaussian blur, sigma = taps / 2): 1 = tight, 5 = very clumpy
//!TYPE DEFINE
//!MINIMUM 1
//!MAXIMUM 5
2

//!PARAM shadow_cutoff
//!DESC no grain at or below this display luma (keeps blacks clean)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.04

//!PARAM shadow_knee
//!DESC full grain from this display luma up
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.18

//!PARAM highlight_knee
//!DESC grain starts fading above this display luma
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
0.80

//!PARAM highlight_cutoff
//!DESC no grain at or above this display luma (above 1.0 = some grain stays on white)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
1.00

//!PARAM grain_rate
//!DESC -1 = new grain every video frame, 0 = static, N > 0 = N new patterns per second of video
//!TYPE float
//!MINIMUM -1.0
//!MAXIMUM 1000.0
-1.0

//!PARAM clamp_output
//!DESC 1 = clamp to 0-1 after adding grain; 0 = no clamp (only useful on stages with values above 1)
//!TYPE DEFINE
//!MINIMUM 0
//!MAXIMUM 1
1

//!PARAM PTS
//!DESC set by mpv to the current frame's timestamp in seconds; leave it alone
//!TYPE float
0.0

//!HOOK LUMA
//!HOOK RGB
//!BIND HOOKED
//!WHEN intensity 0 >
//!DESC film grain v3.1 (smooth)
//!COMPUTE 16 8

#if taps < 1 || taps > 5
#error taps must be 1 to 5
#endif

// One invocation per output pixel: threads = block size (the COMPUTE line above).
const ivec2 WG = ivec2(gl_WorkGroupSize.xy);
const int   KW = 2 * taps + 1;          // kernel width
const int   NX = WG.x + 2 * taps;       // grain tile: the block plus a taps-wide apron
const int   NY = WG.y + 2 * taps;

shared float s_grain[NX * NY];          // raw grain, block + apron
shared float s_hblur[WG.x * NY];        // rows blurred horizontally (separate array: no race)

// PCG3D integer hash (Jarzynski & Olano 2020): no float precision loss at high resolutions
// and no visible lattice.
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

// Uniform [0,1) -> gaussian via an approximation of the gaussian quantile function.
// The input is squeezed to [0.025, 0.975], so the output is a gaussian truncated at
// +-1.96 sigma and scaled to [-0.5, 0.5]; its standard deviation is 0.222.
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

float grain_at(ivec2 cell, uint seed)
{
    return to_gaussian(float(hash3(uvec3(uvec2(cell + 32768), seed))) * (1.0 / 4294967296.0));
}

// Seeded from the frame's timestamp, not the built-in frame counter: the counter advances on
// every render, including redraws and screenshots of a paused frame, so a screenshot did not
// show the grain that was on screen. The timestamp stays put while paused.
// For grain_rate > 0, the 2 ms added before quantising absorbs timestamps rounded to the
// millisecond, so frames that fall exactly on a pattern boundary start the new pattern.
uint grain_seed()
{
    if (grain_rate < 0.0)
        return floatBitsToUint(PTS);                               // every video frame
    if (grain_rate > 0.0)
        return floatBitsToUint(floor((PTS + 0.002) * grain_rate)); // N patterns per second
    return 0u;                                                     // static
}

// smoothstep() that stays defined when e0 >= e1 (then it is a hard step at e0)
float ramp(float e0, float e1, float x)
{
    float t = clamp((x - e0) / max(e1 - e0, 1e-6), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Adds grain g (a to_gaussian() value) to color, weighted by brightness.
vec4 add_grain(vec4 color, float g)
{
#ifdef LUMA_tex
    // Luma plane of YUV video. Values here are raw code values: limited ("TV") range puts
    // black and white at 16 and 235 times 2^(bits-8), out of 2^bits - 1 (16/255 and 235/255
    // for 8-bit, 64/1023 and 940/1023 for 10-bit). Normalising with 16/256 and 235/256 lands
    // black at or just above 0 and white at or just above 1 for every bit depth, so the masks
    // remove grain from both completely. The grain itself is scaled to the same on-screen size
    // as on RGB stages (exact for 8-bit, 0.3% stronger for 10-bit). The shader cannot see the
    // file's range: on full-range YUV (also JPEG stills and grayscale images) the weights shift
    // and the grain is about 14% weaker - for such files replace LUMA by MAIN in the HOOK lines.
    float l = (color.x - 16.0 / 256.0) * (256.0 / 219.0);
#else
    // RGB stages (RGB sources, or MAIN / SCALED / OUTPUT if you move the hook): BT.709 luma.
    float l = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
#endif

    // Film responds least in the toe and shoulder. Flat grain lifts black level and sparkles
    // in highlights, which a sharpener then amplifies.
    l = clamp(l, 0.0, 1.0);
    float w = ramp(shadow_cutoff, shadow_knee, l) * (1.0 - ramp(highlight_knee, highlight_cutoff, l));
    float d = intensity * w * g;

#ifdef LUMA_tex
    color.x += d * (219.0 / 255.0);
#if clamp_output
    color.x = clamp(color.x, 0.0, 1.0);
#endif
#else
    color.rgb += vec3(d);
#if clamp_output
    color.rgb = clamp(color.rgb, 0.0, 1.0);
#endif
#endif
    return color;
}

void hook()
{
    uint  seed = grain_seed();
    ivec2 lid  = ivec2(gl_LocalInvocationID.xy);
    int   li   = int(gl_LocalInvocationIndex);
    int   nthr = WG.x * WG.y;
    ivec2 org  = ivec2(gl_WorkGroupID.xy) * WG;  // first output pixel of this block
    ivec2 base = org - ivec2(taps);              // first grain sample, apron included

    // Gaussian kernel, sigma = taps / 2 - the same kernels as v2, unnormalised (normalising is
    // unnecessary because of the variance correction below).
    float wt[KW];
    float wss = 0.0;
    for (int k = 0; k < KW; k++) {
        float x = float(k - taps);
        wt[k] = exp(-2.0 * x * x / float(taps * taps));
        wss += wt[k] * wt[k];
    }

    // 1. Grain for the block and its apron, seeded by global pixel position: neighbouring
    //    blocks generate identical apron values, so no seams appear at block borders.
    for (int i = li; i < NX * NY; i += nthr)
        s_grain[i] = grain_at(base + ivec2(i % NX, i / NX), seed);

    memoryBarrierShared();
    barrier();

    // 2. Horizontal blur of every row the vertical pass needs (block rows plus apron rows).
    for (int i = li; i < WG.x * NY; i += nthr) {
        int x = i % WG.x;
        int y = i / WG.x;
        float s = 0.0;
        for (int k = 0; k < KW; k++)
            s += wt[k] * s_grain[y * NX + x + k];
        s_hblur[i] = s;
    }

    memoryBarrierShared();
    barrier();

    // 3. Vertical blur. A separable blur of independent samples scales their standard
    //    deviation by sum(w^2) of the 1D kernel; divide it out so the grain is as strong as
    //    the fine version's.
    float g = 0.0;
    for (int k = 0; k < KW; k++)
        g += wt[k] * s_hblur[(lid.y + k) * WG.x + lid.x];
    g /= wss;

    // Edge blocks stick out past the right/bottom of the image: those invocations store
    // nothing. This comes after the last barrier because every invocation must reach both.
    ivec2 pos = org + lid;
    if (any(greaterThanEqual(pos, imageSize(out_image))))
        return;

    imageStore(out_image, pos, add_grain(HOOKED_tex(HOOKED_map(pos)), g));
}
