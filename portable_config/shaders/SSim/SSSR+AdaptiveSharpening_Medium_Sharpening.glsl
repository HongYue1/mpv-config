// ============================================================================
// SSimSuperRes + Adaptive-Sharpen (confidence-gated fusion)
// SSSR: derived from Shiandow (LGPL v3.0+). Adaptive-sharpen: bacondither (BSD-2).
// Fusion: adaptive-sharpen reuses SSSR var/covariance confidence to modulate
//         sharpening strength. Upscale-only (SSSR var texture required).
//
// Maintenance notes (2026 revision):
// - Variance/covariance is stored pre-multiplied by SSSR_VAR_SCALE and divided
//   back to natural magnitude immediately on read. Intermediate textures are
//   rgba16f by default (mpv --fbo-format auto), where raw variance (~1e-6) lands
//   in the fp16 denormal range; the scale preserves precision with no change to
//   the math. SSSR_VAR_SCALE must be identical in every pass that touches it.
// - The downscale passes read via *_raw and honor *_mul but NOT *_rot, so they
//   assume HOOKED_rot is identity at POSTKERNEL (true for normal configs). Do
//   not reuse them on rotated internal hook points without adding *_rot handling.
// - Sharpening strength (SSSR_OVERSHARP + adaptive-sharpen curve_height/gates)
//   is intentionally left as-is: both passes already clamp overshoot via
//   independent anti-ringing, so lowering it would only reduce real detail.
// ============================================================================

// SSimSuperRes Improved
// Derived from SSimSuperRes by Shiandow
// Original license: LGPL v3.0 or later

// ============================================================================
// Pass 1: Vertical downscale into LOWRES
// ============================================================================

//!HOOK POSTKERNEL
//!BIND HOOKED
//!SAVE LOWRES
//!HEIGHT NATIVE_CROPPED.h
//!WHEN NATIVE_CROPPED.w OUTPUT.w < NATIVE_CROPPED.h OUTPUT.h < +
//!COMPONENTS 4
//!DESC SSSR Downscale Y

const vec3  SSSR_LUMA = vec3(0.2126, 0.7152, 0.0722);
const float SSSR_EPS = 1e-8;
const float SSSR_VAR_EPS = 5e-7;
const float SSSR_VAR_SCALE = 1024.0; // fp16 storage scale; undone immediately on read

// Exact Mitchell-Netravali, B = C = 1/3.
// Support radius: 2.
float sssrMitchell(float x)
{
    x = abs(x);

    if (x >= 2.0)
        return 0.0;

    if (x < 1.0) {
        return ((7.0 / 6.0) * x - 2.0) * x * x + 8.0 / 9.0;
    } else {
        return (((-7.0 / 18.0) * x + 2.0) * x - 10.0 / 3.0) * x + 16.0 / 9.0;
    }
}

float sssrSqLuma(vec3 c)
{
    return dot(c * c, SSSR_LUMA);
}

vec4 hook()
{
    float center = HOOKED_pos.y * HOOKED_size.y - 0.5;
    float radius = 2.0 * HOOKED_size.y / input_size.y;

    float lo = ceil(center - radius);
    float hi = floor(center + radius);

    vec2 p = HOOKED_pos;

    vec3  rgbSum = vec3(0.0);
    float sqLumSum = 0.0;
    float weightSum = 0.0;

    for (float k = lo; k <= hi; k += 1.0) {
        p.y = HOOKED_pt.y * (k + 0.5);

        float rel = (p.y - HOOKED_pos.y) * input_size.y;
        float w = sssrMitchell(rel);

        vec3 c = textureLod(HOOKED_raw, p, 0.0).rgb * HOOKED_mul;

        rgbSum += w * c;
        sqLumSum += w * sssrSqLuma(c);
        weightSum += w;
    }

    float invW = 1.0 / max(weightSum, SSSR_EPS);

    vec3 mean = rgbSum * invW;
    float meanSqLum = sqLumSum * invW;

    float v = max(abs(meanSqLum - sssrSqLuma(mean)), SSSR_VAR_EPS);

    return vec4(mean, v * SSSR_VAR_SCALE);
}


// ============================================================================
// Pass 2: Horizontal downscale into LOWRES
// ============================================================================

//!HOOK POSTKERNEL
//!BIND LOWRES
//!SAVE LOWRES
//!WIDTH NATIVE_CROPPED.w
//!HEIGHT NATIVE_CROPPED.h
//!WHEN NATIVE_CROPPED.w OUTPUT.w < NATIVE_CROPPED.h OUTPUT.h < +
//!COMPONENTS 4
//!DESC SSSR Downscale X

const vec3  SSSR_LUMA = vec3(0.2126, 0.7152, 0.0722);
const float SSSR_EPS = 1e-8;
const float SSSR_VAR_EPS = 5e-7;
const float SSSR_VAR_SCALE = 1024.0; // fp16 storage scale; undone immediately on read

float sssrMitchell(float x)
{
    x = abs(x);

    if (x >= 2.0)
        return 0.0;

    if (x < 1.0) {
        return ((7.0 / 6.0) * x - 2.0) * x * x + 8.0 / 9.0;
    } else {
        return (((-7.0 / 18.0) * x + 2.0) * x - 10.0 / 3.0) * x + 16.0 / 9.0;
    }
}

float sssrSqLuma(vec3 c)
{
    return dot(c * c, SSSR_LUMA);
}

vec4 hook()
{
    float center = LOWRES_pos.x * LOWRES_size.x - 0.5;
    float radius = 2.0 * LOWRES_size.x / input_size.x;

    float lo = ceil(center - radius);
    float hi = floor(center + radius);

    vec2 p = LOWRES_pos;

    vec3  rgbSum = vec3(0.0);
    float sqLumSum = 0.0;
    float prevVarSum = 0.0;
    float weightSum = 0.0;

    for (float k = lo; k <= hi; k += 1.0) {
        p.x = LOWRES_pt.x * (k + 0.5);

        float rel = (p.x - LOWRES_pos.x) * input_size.x;
        float w = sssrMitchell(rel);

        vec4 s = textureLod(LOWRES_raw, p, 0.0);
        vec3 c = s.rgb * LOWRES_mul;

        rgbSum += w * c;
        sqLumSum += w * sssrSqLuma(c);

        // Correctly filter pass-1 vertical variance along with RGB.
        // s.a is stored pre-scaled (fp16 precision); restore natural magnitude here.
        prevVarSum += w * (s.a / SSSR_VAR_SCALE);

        weightSum += w;
    }

    float invW = 1.0 / max(weightSum, SSSR_EPS);

    vec3 mean = rgbSum * invW;
    float meanSqLum = sqLumSum * invW;

    float thisVar = max(abs(meanSqLum - sssrSqLuma(mean)), SSSR_VAR_EPS);
    float prevVar = max(prevVarSum * invW, 0.0);

    return vec4(mean, (thisVar + prevVar) * SSSR_VAR_SCALE);
}


// ============================================================================
// Pass 3: Single-pass structural variance/covariance
// ============================================================================

//!HOOK POSTKERNEL
//!BIND PREKERNEL
//!BIND LOWRES
//!SAVE var
//!WIDTH NATIVE_CROPPED.w
//!HEIGHT NATIVE_CROPPED.h
//!WHEN NATIVE_CROPPED.w OUTPUT.w < NATIVE_CROPPED.h OUTPUT.h < +
//!COMPONENTS 4
//!DESC SSSR Variance/Covariance

const vec3  SSSR_LUMA = vec3(0.2126, 0.7152, 0.0722);
const float SSSR_VAR_FLOOR = 1e-6;
const float SSSR_VAR_SCALE = 1024.0; // fp16 storage scale; undone on read by consumers

// Normalized cross-window weights:
// center = 0.5, four cardinal neighbors = 0.125 each.
// This is equivalent to original spread = 0.25, norm = 1 / 2.
const float SSSR_W_CENTER = 0.5;
const float SSSR_W_SIDE   = 0.125;

float sssrLinLuma(vec3 c)
{
    return dot(c, SSSR_LUMA);
}

void sssrAccumSample(
    vec3 l,
    vec3 h,
    float w,
    inout vec3 meanL,
    inout vec3 meanH,
    inout vec3 meanLL,
    inout vec3 meanHH,
    inout vec3 meanLH
) {
    meanL  += w * l;
    meanH  += w * h;
    meanLL += w * l * l;
    meanHH += w * h * h;
    meanLH += w * l * h;
}

vec4 hook()
{
    vec2 baseL = PREKERNEL_pos * input_size + tex_offset;

    vec3 meanL  = vec3(0.0);
    vec3 meanH  = vec3(0.0);
    vec3 meanLL = vec3(0.0);
    vec3 meanHH = vec3(0.0);
    vec3 meanLH = vec3(0.0);

    vec3 l;
    vec3 h;

    l = PREKERNEL_tex(PREKERNEL_pt * (baseL + vec2( 0.0,  0.0))).rgb;
    h = LOWRES_texOff(vec2( 0.0,  0.0)).rgb;
    sssrAccumSample(l, h, SSSR_W_CENTER, meanL, meanH, meanLL, meanHH, meanLH);

    l = PREKERNEL_tex(PREKERNEL_pt * (baseL + vec2(-1.0,  0.0))).rgb;
    h = LOWRES_texOff(vec2(-1.0,  0.0)).rgb;
    sssrAccumSample(l, h, SSSR_W_SIDE, meanL, meanH, meanLL, meanHH, meanLH);

    l = PREKERNEL_tex(PREKERNEL_pt * (baseL + vec2( 1.0,  0.0))).rgb;
    h = LOWRES_texOff(vec2( 1.0,  0.0)).rgb;
    sssrAccumSample(l, h, SSSR_W_SIDE, meanL, meanH, meanLL, meanHH, meanLH);

    l = PREKERNEL_tex(PREKERNEL_pt * (baseL + vec2( 0.0, -1.0))).rgb;
    h = LOWRES_texOff(vec2( 0.0, -1.0)).rgb;
    sssrAccumSample(l, h, SSSR_W_SIDE, meanL, meanH, meanLL, meanHH, meanLH);

    l = PREKERNEL_tex(PREKERNEL_pt * (baseL + vec2( 0.0,  1.0))).rgb;
    h = LOWRES_texOff(vec2( 0.0,  1.0)).rgb;
    sssrAccumSample(l, h, SSSR_W_SIDE, meanL, meanH, meanLL, meanHH, meanLH);

    // Correct single-pass forms:
    // Var(L)   = E[L²]  - E[L]²
    // Var(H)   = E[H²]  - E[H]²
    // Cov(L,H) = E[LH]  - E[L]E[H]
    //
    // Important: do NOT square these vectors again before luma projection.
    vec3 varL3 = max(meanLL - meanL * meanL, vec3(0.0));
    vec3 varH3 = max(meanHH - meanH * meanH, vec3(0.0));
    vec3 covLH3 = meanLH - meanL * meanH;

    float varL = max(sssrLinLuma(varL3), SSSR_VAR_FLOOR);
    float varH = max(sssrLinLuma(varH3), SSSR_VAR_FLOOR);
    float covLH = sssrLinLuma(covLH3);

    // Scale only for storage; consumers divide by SSSR_VAR_SCALE on read.
    return vec4(varL * SSSR_VAR_SCALE, varH * SSSR_VAR_SCALE, covLH * SSSR_VAR_SCALE, 0.0);
}


// ============================================================================
// Pass 4: Covariance/confidence-guided final reconstruction
// ============================================================================

//!HOOK POSTKERNEL
//!BIND HOOKED
//!BIND PREKERNEL
//!BIND LOWRES
//!BIND var
//!WHEN NATIVE_CROPPED.w OUTPUT.w < NATIVE_CROPPED.h OUTPUT.h < +
//!DESC SSSR Final

// Main detail strength (fused build: keep low, adaptive-sharpen does sharpening).
// Original SSSR used oversharp = 0.5.
#define SSSR_OVERSHARP 0.30

// Anti-ringing blend.
// 0.0 = disabled.
// 0.20 - 0.40 recommended.
#define SSSR_ANTIRINGING 0.30

// Correlation gate.
// Detail is injected mostly where PREKERNEL and LOWRES structure agree.
#define SSSR_CORR_LOW  0.05
#define SSSR_CORR_HIGH 0.45

// Safety clamp for the regression/range gain.
#define SSSR_MAX_SLOPE 2.50

const vec3  SSSR_LUMA = vec3(0.2126, 0.7152, 0.0722);
const float SSSR_PI_OVER_3 = 1.04719755119659774615;
const float SSSR_EPS = 1e-6;
const float SSSR_WEIGHT_EPS = 1e-7;
const float SSSR_VAR_SCALE = 1024.0; // must match the variance/downscale passes; values are unscaled to natural magnitude on read

float sssrSqLuma(vec3 c)
{
    return dot(c * c, SSSR_LUMA);
}

float sssrKernel3(float x)
{
    return max(cos(SSSR_PI_OVER_3 * x), 0.0);
}

vec2 sssrConfSlope(vec3 v, float extraVar)
{
    float varL = max(v.x, SSSR_EPS);
    float varH = max(v.y + extraVar, SSSR_EPS);
    float cov  = max(v.z, 0.0);

    float corr = cov * inversesqrt(max(varL * varH, SSSR_EPS));
    corr = clamp(corr, 0.0, 1.0);
    float conf = smoothstep(SSSR_CORR_LOW, SSSR_CORR_HIGH, corr);

    float ratioSlope = sqrt(varL / varH);
    float regSlope = cov / varH;
    float slope = min(regSlope, ratioSlope * SSSR_MAX_SLOPE);

    return vec2(conf, slope);
}

#define SSSR_H(X,Y) LOWRES_tex(LOWRES_pt * (base + vec2(float(X), float(Y))))
#define SSSR_L(X,Y) PREKERNEL_tex(PREKERNEL_pt * (base + tex_offset + vec2(float(X), float(Y)))).rgb
#define SSSR_V(X,Y) var_tex(var_pt * (base + vec2(float(X), float(Y)))).rgb

#define SSSR_ADD_TAP(X,Y,H,K) {                                                        \
vec3 lSample = SSSR_L(X,Y);                                                        \
vec3 vv = SSSR_V(X,Y) / SSSR_VAR_SCALE;                                                             \
\
float colorErr = sssrSqLuma(c0rgb - (H).rgb);                                      \
float w = (K) / (colorErr + (H).a / SSSR_VAR_SCALE + SSSR_WEIGHT_EPS);                              \
\
vec2 confSlope = sssrConfSlope(vv, mVar);                                             \
float conf = confSlope.x; float slope = confSlope.y;                                       \
float r = -(1.0 + SSSR_OVERSHARP) * slope;                                         \
\
vec3 force = lSample - c0rgb + r * ((H).rgb - c0rgb);                              \
\
acc += w * conf * force;                                                           \
weightSum += w;                                                                    \
\
lMin = min(lMin, lSample);                                                         \
lMax = max(lMax, lSample);                                                         \
}

vec4 hook()
{
    vec4 c0 = HOOKED_texOff(vec2(0.0));
    vec3 c0rgb = c0.rgb;

    // Current output position in LOWRES pixel space.
    vec2 lowPos = HOOKED_pos * LOWRES_size - vec2(0.5);

    // taps = 3, odd window, equivalent to round() for positive image coordinates.
    vec2 center = floor(lowPos + vec2(0.5));
    vec2 offset = lowPos - center;

    // Pixel-centered base coordinate for LOWRES / PREKERNEL / var.
    vec2 base = center + vec2(0.5);

    // Cache LOWRES 3x3 once. Used for both mVar and reconstruction.
    vec4 h_mm = SSSR_H(-1, -1);
    vec4 h_0m = SSSR_H( 0, -1);
    vec4 h_pm = SSSR_H( 1, -1);

    vec4 h_m0 = SSSR_H(-1,  0);
    vec4 h_00 = SSSR_H( 0,  0);
    vec4 h_p0 = SSSR_H( 1,  0);

    vec4 h_mp = SSSR_H(-1,  1);
    vec4 h_0p = SSSR_H( 0,  1);
    vec4 h_pp = SSSR_H( 1,  1);

    vec3 hMin = h_00.rgb;
    vec3 hMax = h_00.rgb;

    hMin = min(hMin, h_mm.rgb); hMax = max(hMax, h_mm.rgb);
    hMin = min(hMin, h_0m.rgb); hMax = max(hMax, h_0m.rgb);
    hMin = min(hMin, h_pm.rgb); hMax = max(hMax, h_pm.rgb);
    hMin = min(hMin, h_m0.rgb); hMax = max(hMax, h_m0.rgb);
    hMin = min(hMin, h_p0.rgb); hMax = max(hMax, h_p0.rgb);
    hMin = min(hMin, h_mp.rgb); hMax = max(hMax, h_mp.rgb);
    hMin = min(hMin, h_0p.rgb); hMax = max(hMax, h_0p.rgb);
    hMin = min(hMin, h_pp.rgb); hMax = max(hMax, h_pp.rgb);

    // Same triangular 3x3 alpha smoothing as the original:
    // center 1, edges 0.5, corners 0.25, normalized by total 4.
    float mVar = (0.25 / SSSR_VAR_SCALE) * (
        h_00.a +
        0.5 * (h_m0.a + h_p0.a + h_0m.a + h_0p.a) +
        0.25 * (h_mm.a + h_pm.a + h_mp.a + h_pp.a)
    );

    // Precompute separable 3-tap cosine kernel.
    float kxm = sssrKernel3(-1.0 - offset.x);
    float kx0 = sssrKernel3( 0.0 - offset.x);
    float kxp = sssrKernel3( 1.0 - offset.x);

    float kym = sssrKernel3(-1.0 - offset.y);
    float ky0 = sssrKernel3( 0.0 - offset.y);
    float kyp = sssrKernel3( 1.0 - offset.y);

    vec3 acc = vec3(0.0);
    float weightSum = 0.0;

    vec3 lCenter = SSSR_L(0, 0);
    vec3 lMin = lCenter;
    vec3 lMax = lCenter;

    SSSR_ADD_TAP(-1, -1, h_mm, kxm * kym);
    SSSR_ADD_TAP( 0, -1, h_0m, kx0 * kym);
    SSSR_ADD_TAP( 1, -1, h_pm, kxp * kym);

    SSSR_ADD_TAP(-1,  0, h_m0, kxm * ky0);
    SSSR_ADD_TAP( 0,  0, h_00, kx0 * ky0);
    SSSR_ADD_TAP( 1,  0, h_p0, kxp * ky0);

    SSSR_ADD_TAP(-1,  1, h_mp, kxm * kyp);
    SSSR_ADD_TAP( 0,  1, h_0p, kx0 * kyp);
    SSSR_ADD_TAP( 1,  1, h_pp, kxp * kyp);

    vec3 result = c0rgb + acc / max(weightSum, SSSR_EPS);

    // Conservative anti-ringing.
    // Uses cached LOWRES and already-fetched PREKERNEL extrema.
    vec3 hRange = max(hMax - hMin, vec3(SSSR_EPS));
    vec3 limitPad = hRange * (0.40 + 0.25 * SSSR_OVERSHARP) + vec3(SSSR_EPS);

    vec3 limitMin = min(hMin, c0rgb) - limitPad;
    vec3 limitMax = max(hMax, c0rgb) + limitPad;

    // Allow some PREKERNEL extrema for genuine restored detail.
    limitMin = min(limitMin, mix(hMin, lMin, 0.35));
    limitMax = max(limitMax, mix(hMax, lMax, 0.35));

    vec3 limited = clamp(result, limitMin, limitMax);
    result = mix(result, limited, SSSR_ANTIRINGING);

    c0.rgb = result;
    return c0;
}


// Copyright (c) 2015-2021, bacondither
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer
//    in this position and unchanged.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
// OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
// IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
// NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Adaptive sharpen - version 2021-10-17
// Tuned for use post-resize

//!HOOK OUTPUT
//!BIND HOOKED
//!BIND var
//!WHEN NATIVE_CROPPED.w OUTPUT.w < NATIVE_CROPPED.h OUTPUT.h < +
//!DESC SSSR + adaptive-sharpen (confidence-gated)

//--------------------------------------- Settings ------------------------------------------------

#define curve_height    0.6                  // Main control of sharpening strength [>0]
                                             // 0.3 <-> 2.0 is a reasonable range of values

#define overshoot_ctrl  false                // Allow for higher overshoot if the current edge pixel
                                             // is surrounded by similar edge pixels

// Defined values under this row are "optimal" DO NOT CHANGE IF YOU DO NOT KNOW WHAT YOU ARE DOING!

#define curveslope      0.5                  // Sharpening curve slope, high edge values

#define L_compr_low     0.167                // Light compression, default (0.167=~6x)
#define L_compr_high    0.334                // Light compression, surrounded by edges (0.334=~3x)

#define D_compr_low     0.250                // Dark compression, default (0.250=4x)
#define D_compr_high    0.500                // Dark compression, surrounded by edges (0.500=2x)

#define scale_lim       0.1                  // Abs max change before compression [>0.01]
#define scale_cs        0.056                // Compression slope above scale_lim

#define pm_p            1.0                  // Power mean p-value [>0-1.0]
//-------------------------------------------------------------------------------------------------

// ---- SSSR confidence-gating settings (fused mode) --------------------------
#define SSSR_AS_CONF_FLOOR 0.30   // sharpen multiplier in low-confidence (noisy) areas   [<1 attenuates noise]
#define SSSR_AS_CONF_CEIL  1.00   // sharpen multiplier in high-confidence (real detail)  [>1 boosts trusted detail]
#define SSSR_AS_CORR_LOW   0.05   // correlation below this => fully uncertain (keep in sync with Pass 4 SSSR_CORR_LOW)
#define SSSR_AS_CORR_HIGH  0.45   // correlation above this => fully trusted   (keep in sync with Pass 4 SSSR_CORR_HIGH)
#define SSSR_AS_EPS        1e-6
#define SSSR_VAR_SCALE     1024.0 // must match the SSSR variance/downscale passes
#define SSSR_AS_PROTECT_SAT false // experimental: preserve saturation on sharpened edges (false = original behavior)

#define max4(a,b,c,d)  ( max(max(a, b), max(c, d)) )

// Soft if, fast linear approx
#define soft_if(a,b,c) ( sat((a + b + c + 0.056/2.5)/(maxedge + 0.03/2.5) - 0.85) )

// Soft limit, modified tanh approx
#define soft_lim(v,s)  ( sat(abs(v/s)*(27.0 + pow(v/s, 2.0))/(27.0 + 9.0*pow(v/s, 2.0)))*s )

// Weighted power mean
#define wpmean(a,b,w)  ( pow(w*pow(abs(a), pm_p) + abs(1.0-w)*pow(abs(b), pm_p), (1.0/pm_p)) )

// Get destination pixel values
#define get(x,y)       ( HOOKED_texOff(vec2(x, y)).rgb )
#define sat(x)         ( clamp(x, 0.0, 1.0) )
#define dxdy(val)      ( length(fwidth(val)) ) // =~1/2.5 hq edge without c_comp

#ifdef LUMA_tex
#define CtL(RGB)       RGB.x
#else
#define CtL(RGB)       ( sqrt(dot(sat(RGB)*sat(RGB), vec3(0.2126, 0.7152, 0.0722))) )
#endif

#define b_diff(pix)    ( (blur-luma[pix])*(blur-luma[pix]) )

vec4 hook() {

    // [                c22               ]
    // [           c24, c9,  c23          ]
    // [      c21, c1,  c2,  c3, c18      ]
    // [ c19, c10, c4,  c0,  c5, c11, c16 ]
    // [      c20, c6,  c7,  c8, c17      ]
    // [           c15, c12, c14          ]
    // [                c13               ]
    vec3 c[25] = vec3[](get( 0, 0), get(-1,-1), get( 0,-1), get( 1,-1), get(-1, 0),
                        get( 1, 0), get(-1, 1), get( 0, 1), get( 1, 1), get( 0,-2),
                        get(-2, 0), get( 2, 0), get( 0, 2), get( 0, 3), get( 1, 2),
                        get(-1, 2), get( 3, 0), get( 2, 1), get( 2,-1), get(-3, 0),
                        get(-2, 1), get(-2,-1), get( 0,-3), get( 1,-2), get(-1,-2));

    float e[13] = float[](dxdy(c[0]),  dxdy(c[1]),  dxdy(c[2]),  dxdy(c[3]),  dxdy(c[4]),
                          dxdy(c[5]),  dxdy(c[6]),  dxdy(c[7]),  dxdy(c[8]),  dxdy(c[9]),
                          dxdy(c[10]), dxdy(c[11]), dxdy(c[12]));

    // RGB to luma
    float luma[25] = float[](CtL(c[0]), CtL(c[1]), CtL(c[2]), CtL(c[3]), CtL(c[4]), CtL(c[5]), CtL(c[6]),
                             CtL(c[7]),  CtL(c[8]),  CtL(c[9]),  CtL(c[10]), CtL(c[11]), CtL(c[12]),
                             CtL(c[13]), CtL(c[14]), CtL(c[15]), CtL(c[16]), CtL(c[17]), CtL(c[18]),
                             CtL(c[19]), CtL(c[20]), CtL(c[21]), CtL(c[22]), CtL(c[23]), CtL(c[24]));

    float c0_Y = luma[0];

    // Blur, gauss 3x3
    float  blur   = (2.0 * (luma[2]+luma[4]+luma[5]+luma[7]) + (luma[1]+luma[3]+luma[6]+luma[8]) + 4.0 * luma[0]) / 16.0;

    // Contrast compression, center = 0.5
    float c_comp = sat(0.266666681f + 0.9*exp2(blur * blur * -7.4));

    // Edge detection
    // Relative matrix weights
    // [          1          ]
    // [      4,  5,  4      ]
    // [  1,  5,  6,  5,  1  ]
    // [      4,  5,  4      ]
    // [          1          ]
    float edge = ( 1.38*b_diff(0)
                 + 1.15*(b_diff(2) + b_diff(4) + b_diff(5) + b_diff(7))
                 + 0.92*(b_diff(1) + b_diff(3) + b_diff(6) + b_diff(8))
                 + 0.23*(b_diff(9) + b_diff(10) + b_diff(11) + b_diff(12)) ) * c_comp;

    vec2 cs = vec2(L_compr_low,  D_compr_low);

    if (overshoot_ctrl) {
        float maxedge = max4( max4(e[1],e[2],e[3],e[4]), max4(e[5],e[6],e[7],e[8]),
                              max4(e[9],e[10],e[11],e[12]), e[0] );

        // [          x          ]
        // [       z, x, w       ]
        // [    z, z, x, w, w    ]
        // [ y, y, y, 0, y, y, y ]
        // [    w, w, x, z, z    ]
        // [       w, x, z       ]
        // [          x          ]
        float sbe = soft_if(e[2],e[9], dxdy(c[22]))*soft_if(e[7],e[12],dxdy(c[13]))  // x dir
                  + soft_if(e[4],e[10],dxdy(c[19]))*soft_if(e[5],e[11],dxdy(c[16]))  // y dir
                  + soft_if(e[1],dxdy(c[24]),dxdy(c[21]))*soft_if(e[8],dxdy(c[14]),dxdy(c[17]))  // z dir
                  + soft_if(e[3],dxdy(c[23]),dxdy(c[18]))*soft_if(e[6],dxdy(c[20]),dxdy(c[15])); // w dir

        cs = mix(cs, vec2(L_compr_high, D_compr_high), sat(2.4002*sbe - 2.282));
    }

    // Precalculated default squared kernel weights
    const vec3 w1 = vec3(0.5,           1.0, 1.41421356237); // 0.25, 1.0, 2.0
    const vec3 w2 = vec3(0.86602540378, 1.0, 0.54772255751); // 0.75, 1.0, 0.3

    // Transition to a concave kernel if the center edge val is above thr
    vec3 dW = pow(mix( w1, w2, sat(2.4*edge - 0.82)), vec3(2.0));

    // Use lower weights for pixels in a more active area relative to center pixel area
    // This results in narrower and less visible overshoots around sharp edges
    float modif_e0 = 3.0 * e[0] + 0.02/2.5;

    float weights[12]  = float[](( min(modif_e0/e[1],  dW.y) ),
                                 ( dW.x ),
                                 ( min(modif_e0/e[3],  dW.y) ),
                                 ( dW.x ),
                                 ( dW.x ),
                                 ( min(modif_e0/e[6],  dW.y) ),
                                 ( dW.x ),
                                 ( min(modif_e0/e[8],  dW.y) ),
                                 ( min(modif_e0/e[9],  dW.z) ),
                                 ( min(modif_e0/e[10], dW.z) ),
                                 ( min(modif_e0/e[11], dW.z) ),
                                 ( min(modif_e0/e[12], dW.z) ));

    weights[0] = (max(max((weights[8]  + weights[9])/4.0,  weights[0]), 0.25) + weights[0])/2.0;
    weights[2] = (max(max((weights[8]  + weights[10])/4.0, weights[2]), 0.25) + weights[2])/2.0;
    weights[5] = (max(max((weights[9]  + weights[11])/4.0, weights[5]), 0.25) + weights[5])/2.0;
    weights[7] = (max(max((weights[10] + weights[11])/4.0, weights[7]), 0.25) + weights[7])/2.0;

    // Calculate the negative part of the laplace kernel and the low threshold weight
    float lowthrsum   = 0.0;
    float weightsum   = 0.0;
    float neg_laplace = 0.0;

    for (int pix = 0; pix < 12; ++pix)
    {
        float lowthr = sat((20.*4.5*c_comp*e[pix + 1] - 0.221));

        neg_laplace += luma[pix+1] * luma[pix+1] * weights[pix] * lowthr;
        weightsum   += weights[pix] * lowthr;
        lowthrsum   += lowthr / 12.0;
    }

    neg_laplace = sqrt(neg_laplace / weightsum);

    // Compute sharpening magnitude function
    float sharpen_val = curve_height/(curve_height*curveslope*edge + 0.625);

    // Calculate sharpening diff and scale
    float sharpdiff = (c0_Y - neg_laplace)*(lowthrsum*sharpen_val + 0.01);

    // --- SSSR confidence gating ------------------------------------------
    // Reuse SSSR variance/covariance: sharpen where SSSR found real,
    // structurally-agreeing detail; back off in low-confidence (noisy) areas.
    {
        vec3  vv   = var_tex(HOOKED_pos).rgb / SSSR_VAR_SCALE;   // (varL, varH, covLH); undo storage scale
        float vL   = max(vv.x, SSSR_AS_EPS);
        float vH   = max(vv.y, SSSR_AS_EPS);
        float cvar = max(vv.z, 0.0);
        float corr = clamp(cvar * inversesqrt(max(vL * vH, SSSR_AS_EPS)), 0.0, 1.0);
        float conf = smoothstep(SSSR_AS_CORR_LOW, SSSR_AS_CORR_HIGH, corr);
        sharpdiff *= mix(SSSR_AS_CONF_FLOOR, SSSR_AS_CONF_CEIL, conf);
    }
    // ---------------------------------------------------------------------

    // Calculate local near min & max, partial sort
    float temp;

    for (int i1 = 0; i1 < 24; i1 += 2)
    {
        temp = luma[i1];
        luma[i1]   = min(luma[i1], luma[i1+1]);
        luma[i1+1] = max(temp, luma[i1+1]);
    }

    for (int i2 = 24; i2 > 0; i2 -= 2)
    {
        temp = luma[0];
        luma[0]    = min(luma[0], luma[i2]);
        luma[i2]   = max(temp, luma[i2]);

        temp = luma[24];
        luma[24] = max(luma[24], luma[i2-1]);
        luma[i2-1] = min(temp, luma[i2-1]);
    }

    float min_dist  = min(abs(luma[24] - c0_Y), abs(c0_Y - luma[0]));
    min_dist = min(min_dist, scale_lim*(1.0 - scale_cs) + min_dist*scale_cs);

    // Soft limited anti-ringing with tanh, wpmean to control compression slope
    sharpdiff = wpmean(max(sharpdiff, 0.0), soft_lim( max(sharpdiff, 0.0), min_dist ), cs.x )
              - wpmean(min(sharpdiff, 0.0), soft_lim( min(sharpdiff, 0.0), min_dist ), cs.y );
    
    float sharpdiff_lim = sat(c0_Y + sharpdiff) - c0_Y;

    if (SSSR_AS_PROTECT_SAT) {
        // Scale chroma alongside the luma change so saturated edges don't wash out.
        float satmul = (c0_Y + max(sharpdiff_lim*0.9, sharpdiff_lim)*1.03 + 0.03)/(c0_Y + 0.03);
        vec3  res    = c0_Y + sharpdiff_lim + (c[0] - c0_Y)*satmul;
        return vec4(res, HOOKED_texOff(0).a);
    }

    return vec4(sharpdiff_lim + c[0], HOOKED_texOff(0).a);
}
