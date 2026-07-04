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

    return vec4(mean, v);
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
        prevVarSum += w * s.a;

        weightSum += w;
    }

    float invW = 1.0 / max(weightSum, SSSR_EPS);

    vec3 mean = rgbSum * invW;
    float meanSqLum = sqLumSum * invW;

    float thisVar = max(abs(meanSqLum - sssrSqLuma(mean)), SSSR_VAR_EPS);
    float prevVar = max(prevVarSum * invW, 0.0);

    return vec4(mean, thisVar + prevVar);
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

    return vec4(varL, varH, covLH, 0.0);
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

// Main detail strength.
// Original SSSR used oversharp = 0.5.
#define SSSR_OVERSHARP 0.50

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
vec3 vv = SSSR_V(X,Y);                                                             \
\
float colorErr = sssrSqLuma(c0rgb - (H).rgb);                                      \
float w = (K) / (colorErr + (H).a + SSSR_WEIGHT_EPS);                              \
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
    float mVar = 0.25 * (
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
