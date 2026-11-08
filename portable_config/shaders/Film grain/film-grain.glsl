// film-grain.glsl - fine film grain for mpv, v3.1
//
// Per-pixel gaussian grain, weighted by brightness. Masks banding, blocking and mosquito noise
// in low-bitrate video and gives a following sharpener texture to work on instead of artifacts.
//
// Where it runs
//   * YUV video (almost all video): on the luma plane before scaling, the same place as v2.
//   * RGB sources (PNG stills, RGB video): on the RGB plane. v2 hooked only the luma
//     plane, so it silently did nothing for these.
//   * JPEG stills and grayscale images decode as full-range YUV / gray, so they take the luma
//     path with its full-range caveat (see add_grain below).
//   * Grain at screen resolution instead (e.g. 1080p on a 4K screen, after an upscaler or
//     sharpener): replace the two HOOK directive lines below with one HOOK directive naming
//     OUTPUT. The code detects the stage, so no other edit is needed.
//
// Use vo=gpu-next (mpv's default). With vo=gpu, mpv 0.41.0 rejects PARAM blocks and does not
// load this file at all; the nightly tested (v0.41.0-1288) accepts it with vo=gpu too.
//
// Tuning without editing the file, in mpv.conf:
//   glsl-shader-opts=film-grain/intensity=0.07,film-grain/grain_rate=12
// "film-grain" is this file's name without ".glsl"; rename the file and the prefix changes too.
// Without a prefix, a value applies to every loaded shader with a parameter of that name.
// To change a default permanently, edit the number on the last line of its PARAM block.
// intensity=0 switches the pass off completely (it is skipped, so the image is untouched).
//
// Changes from v3:
//   * grain_rate > 0 keeps a steady cadence. Container timestamps are often rounded to the
//     millisecond (Matroska), so a frame due exactly on a pattern boundary could arrive a
//     fraction of a millisecond early and keep the old pattern: on 24 fps MKV, grain_rate=24
//     froze the grain on every third frame and grain_rate=12 ran 3,1,2 frames instead of 2,2,2.
//   * Luma range normalised so that limited-range black and white get no grain at every bit
//     depth; 10-bit white previously received a faint residue.
//   * grain_size > 1: the interpolation lattice moves to a random offset for each new pattern,
//     so its grid does not stand still on screen while the grain animates.
//   * intensity=0 skips the pass (a WHEN condition) instead of running it to add nothing.

//!PARAM intensity
//!DESC grain strength in display units (0-1 RGB): RMS = 0.22 x intensity. 0.025 subtle, 0.09 heavy
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.052

//!PARAM grain_size
//!DESC 1 = one grain per pixel; 1.5-2.5 = coarser, filmic grain
//!TYPE float
//!MINIMUM 1.0
//!MAXIMUM 8.0
1.0

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
//!DESC film grain v3.1 (fine)

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

float grain_field(vec2 px, uint seed)   // px: pixel coordinates (pixel centres at n + 0.5)
{
    if (grain_size == 1.0)              // one grain per pixel: a single lookup
        return grain_at(ivec2(floor(px)), seed);

    // Coarser grain: interpolate a lattice of grain_size-pixel cells with smoothstep weights.
    // Each new pattern shifts the lattice by a random fraction of a cell. Interpolated noise is
    // sharper next to lattice points than between them; with a fixed lattice that grid stays in
    // the same place while the grain animates, and the eye picks it out.
    uint  h  = hash3(uvec3(seed, 0x68e31da4u, 0xb5297a4du));
    vec2  gp = px / grain_size - 0.5 + vec2(uvec2(h, h >> 16u) & 0xffffu) * (1.0 / 65536.0);
    ivec2 c  = ivec2(floor(gp));
    vec2  f  = fract(gp);
    vec2  w1 = f * f * (3.0 - 2.0 * f);
    vec2  w0 = 1.0 - w1;

    float g = w0.x * w0.y * grain_at(c,               seed)
            + w1.x * w0.y * grain_at(c + ivec2(1, 0), seed)
            + w0.x * w1.y * grain_at(c + ivec2(0, 1), seed)
            + w1.x * w1.y * grain_at(c + ivec2(1, 1), seed);

    // Interpolating independent gaussians lowers their variance; undo that so coarse grain
    // is as strong as fine grain.
    float ss = (w0.x * w0.x + w1.x * w1.x) * (w0.y * w0.y + w1.y * w1.y);
    return g * inversesqrt(max(ss, 1e-6));
}

vec4 hook()
{
    float g = grain_field(HOOKED_pos * HOOKED_size, grain_seed());
    return add_grain(HOOKED_tex(HOOKED_pos), g);
}
