// Auto-generated shader header - Do not edit!
#pragma once

#include <unordered_map>
#include <string>

inline const std::unordered_map<std::string, const char*> SHADERS = {
    {"liquidglass.frag", R"GLSL(
#version 300 es
precision highp float;

/*
 * Apple-style Liquid Glass Fragment Shader — Thick-glass refraction model
 *
 * The window is modeled as a thick convex glass slab:
 *   - Center: flat surface → clean frosted blur, no distortion
 *   - Edges: curved surface → refraction pulls in content from beyond
 *     the window boundary, creating natural color bleeding
 *
 * Rendering layers:
 * 1. Edge refraction via smooth outward direction + exponential proximity
 * 2. Chromatic aberration (per-channel refraction scale)
 * 3. Edge raw-texture blend for vivid color pickup
 * 4. Subtle center dome lens magnification
 * 5. Frosted tint (brightness boost + desaturation)
 * 6. Configurable color tint overlay
 * 7. Fresnel edge glow
 * 8. Specular highlight (top)
 * 9. Inner shadow (bottom rim)
 */

uniform sampler2D tex;
uniform vec2 fullSize;
uniform float radius;
uniform vec2 uvPadding;

uniform float refractionStrength;
uniform float chromaticAberration;
uniform float fresnelStrength;
uniform float specularStrength;
uniform float glassOpacity;
uniform float edgeThickness;
uniform vec3 tintColor;
uniform float tintAlpha;
uniform float lensDistortion;
uniform float brightness;
uniform float contrast;
uniform float saturation;
uniform float vibrancy;
uniform float vibrancyDarkness;
uniform float adaptiveDim;
uniform float adaptiveBoost;
uniform float roundingPower;

uniform sampler2D maskTex;
uniform int useMask;
uniform vec2 maskUVOffset;
uniform vec2 maskUVScale;
uniform float maskAlphaThreshold;

// Animated caustics. shimmerIntensity == 0.0 skips the whole block, so the
// static path costs exactly what it did before.
uniform float uTime;
uniform float shimmerIntensity;
uniform float shimmerSpeed;
uniform float shimmerScale;
uniform int   shimmerLightFromBackdrop;
uniform sampler2D waveTex;   // R = h(t), G = h(t-1), biased +0.5
uniform float shimmerDepth;  // water depth = projection distance to the floor
uniform float waveSubFrac;   // 0..1 between the two stored sim states

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

// ============================================================================
// TEXTURE SAMPLING (window UV -> padded texture UV)
// ============================================================================

vec2 toTexUV(vec2 wuv) {
    return wuv * (1.0 - 2.0 * uvPadding) + uvPadding;
}

vec4 sampleBlurred(vec2 wuv) {
    vec2 tuv = toTexUV(wuv);
    return texture(tex, clamp(tuv, 0.001, 0.999));
}

// ============================================================================
// SDF
// ============================================================================

float lpNorm(vec2 v, float p) {
    return pow(pow(abs(v.x), p) + pow(abs(v.y), p), 1.0 / p);
}

float getRoundedBoxSDF(vec2 uv, float r) {
    vec2 p = (uv - 0.5) * fullSize;
    vec2 halfSize = fullSize * 0.5;
    float clampedR = min(r, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + clampedR;
    return min(max(q.x, q.y), 0.0) + lpNorm(max(q, 0.0), roundingPower) - clampedR;
}

float getCornerSDF(vec2 uv) {
    return getRoundedBoxSDF(uv, radius);
}

// ============================================================================
// REFRACTION DIRECTION
// Pixel-space direction toward window center — perfectly smooth everywhere,
// no SDF gradient needed. On straight edges the perpendicular pixel distance
// dominates, giving approximately edge-normal direction. At corners it
// naturally follows the diagonal.
// ============================================================================

// ============================================================================
// WAVE-FIELD CAUSTICS
//
// This deliberately does NOT use value/Perlin noise. Procedural noise is
// stationary and band-limited: statistically identical everywhere, forever.
// The eye reads that as fake — nothing is ever surprised, and a loop point is
// always lurking. Real caustics are not a texture, they are what happens when
// light refracts through a moving surface, and real water is a superposition
// of wave trains whose periods do not divide into each other.
//
// So: sum a handful of directional waves at IRRATIONAL frequency ratios
// (1, φ, φ², … — φ being the golden ratio, the least-well-approximated-by-
// rationals number there is). The sum therefore has no common period: it never
// repeats, so there is no seam to notice. Amplitude falls roughly as 1/f,
// matching how energy distributes in real wave fields — big slow swells carry
// the motion, small fast ripples only decorate it.
//
// The caustic itself is the LAPLACIAN of that height field, not the height.
// Light focuses where the surface is concave and spreads where it is convex,
// so brightness follows curvature. That is why this reads as light through
// water rather than as a moving texture pasted on top.
// ============================================================================

const float PHI = 1.61803398875;

// Wave field height AND its exact second derivatives, from one pass.
//
// h(p) = SUM amp_i * sin(k_i . p + w_i t), so every second derivative is just
// that same sin scaled by the wave vector — no finite differences, no extra
// sin() calls. Four sample points were being spent on a numerical Laplacian
// that was both slower and blurrier than the analytic answer.
// Returns (h_xx, h_yy, h_xy).
// ============================================================================
//  SIMULATED SURFACE  (replaces every analytic wave sum that came before)
//
//  h now comes from wavesim.frag, which integrates d2h/dt2 = c^2*lap(h) on a
//  ping-ponged texture. That field has HISTORY: disturbances start somewhere,
//  spread at finite speed, reflect off the edges and interfere with their own
//  reflections, and decay. Every closed-form version tried before this was
//  statistically stationary — identical statistics everywhere, forever — which
//  is precisely the property human pattern recognition locks onto, and no
//  amount of retuning could remove it.
//
//  Derivatives are finite differences of the texture rather than analytic.
//  Noisier, but the surface is the real object now; the noise is honest.
// ============================================================================

// Only the CENTRE of the simulation is ever visible. Disturbances are injected
// in the outer ring, so waves always ARRIVE from off-screen rather than
// appearing out of nowhere in the middle of a window — the "smash" that was so
// obvious before. The ring is off-screen in every direction regardless of how
// the user's monitors are arranged, so no layout detection is needed.
// Half-width of the visible window into the sim. Smaller = the injection ring
// sits proportionally further outside what you can see, so a disturbance has
// more water to cross before it arrives. At 0.34 the ring (radius 0.40-0.49)
// landed only just past the visible edge and the "smash" was still catchable in
// the corner of your eye.
const float VIS = 0.21;

float waveH(vec2 q) {
    // NEITHER fract() NOR clamp(). fract() wrapped, putting a hard seam wherever
    // the coordinate crossed 0/1 — which the edge-refraction zone then stretched
    // into blocky banding along the border. clamp() would instead freeze the
    // value out there, i.e. a flat dead band at the edge: a different artifact,
    // not a fix.
    // The mapping is simply continuous. VIS=0.34 means q in [0,1] uses only the
    // middle third of the texture, so q can wander well outside [0,1] — which is
    // exactly what refraction does to it near an edge — and still land inside
    // real simulated water. GL_CLAMP_TO_EDGE only ever engages far outside the
    // window, where nothing is drawn.
    vec2 uv = 0.5 + (q - 0.5) * (2.0 * VIS);
    // R is the newest state, G the one before it. Blending by how far we are
    // between them makes the motion continuous even when a simulation step
    // spans many frames — which is exactly the case at low speed. Without this,
    // slowing the water down would make it tick between discrete states.
    vec2 hh = texture(waveTex, uv).rg - 0.5;
    return mix(hh.y, hh.x, waveSubFrac);
}

// Slope, for pulling the backdrop sample along the surface normal.
vec2 waveSlope(vec2 q, float e) {
    return vec2(waveH(q + vec2(e, 0.0)) - waveH(q - vec2(e, 0.0)),
                waveH(q + vec2(0.0, e)) - waveH(q - vec2(0.0, e))) / (2.0 * e);
}

// Second derivatives (h_xx, h_yy, h_xy) by central differences.
vec3 waveHessian(vec2 q, float e) {
    float c  = waveH(q);
    float xp = waveH(q + vec2(e, 0.0)), xm = waveH(q - vec2(e, 0.0));
    float yp = waveH(q + vec2(0.0, e)), ym = waveH(q - vec2(0.0, e));
    float pp = waveH(q + vec2( e,  e)), mm = waveH(q + vec2(-e, -e));
    float pm = waveH(q + vec2( e, -e)), mp = waveH(q + vec2(-e,  e));
    float e2 = e * e;
    return vec3((xp - 2.0 * c + xm) / e2,
                (yp - 2.0 * c + ym) / e2,
                (pp - pm - mp + mm) / (4.0 * e2));
}

// One caustic layer: brightness = 1/|det(Jacobian)| of the refraction map
// p -> p + k*grad(h). det crosses zero on a CURVE, which is why caustics are
// thin filaments and not blobs.
float causticLayer(vec2 q, float e, float lens) {
    vec3  H   = waveHessian(q, e);
    float det = (1.0 + lens * H.x) * (1.0 + lens * H.y) - (lens * H.z) * (lens * H.z);
    float ad  = abs(det);
    // Thin bright core inside a soft halo — a single floor gives either a hard
    // wire or a fat smudge; sunlit caustics are both at once.
    float core = clamp(1.0 / max(ad, 0.016) - 1.0, 0.0, 18.0) / 18.0;
    float halo = clamp(1.0 / max(ad, 0.110) - 1.0, 0.0,  5.0) /  5.0;
    return core * 0.85 + halo * 0.10;
}

// THREE SUPERIMPOSED LAYERS.
// Measured against a real pool photo: a single layer, at any density or
// projection distance, never matches it. The photo is several networks at once
// — long swell casts big cells, small ripples cast fine ones, and both project
// simultaneously. Sweeping one layer harder only trades density for sparseness;
// superposition is what produces the overlapping net with bright vertices.
// Each layer gets its own hash seed, so they are independent surfaces rather
// than one surface at three zooms (which would just look like a mip stack).
// Two taps at different finite-difference widths read the SAME simulated
// surface at two scales — the long swell and the fine chop — which is what
// produced the overlapping net in the reference photo.
float caustic(vec2 q) {
    // DEPTH is the distance from the surface to the floor: the further the
    // refracted light travels, the more it converges, so deeper water gives
    // tighter, crisper filaments. It is the same 'k' as the Jacobian lens.
    float d = max(shimmerDepth, 0.05);
    // Two stencils read the long swell and the chop; the wide one needs a
    // proportionally longer throw to focus at all.
    return causticLayer(q, 0.0150, 0.055 * d) * 0.75
         + causticLayer(q, 0.0320, 0.090 * d) * 0.45;
}

vec2 refractionDir(vec2 uv) {
    vec2 toCenterPx = (vec2(0.5) - uv) * fullSize;
    float len = length(toCenterPx);
    return len > 0.1 ? toCenterPx / len : vec2(0.0);
}

// ============================================================================
// MAIN — Thick-glass refraction model
// ============================================================================

void main() {
    vec2 uv = v_texcoord;

    // Layers only: sample the temp FBO to get the rendered surface pixel.
    // Discard fully transparent fragments so glass only covers visible content.
    // For windows, hasMask is false and this block is skipped entirely.
    vec4 surfacePixel = vec4(0.0);
    bool hasMask = (useMask == 1);
    if (hasMask) {
        vec2 maskUV = uv * maskUVScale + maskUVOffset;
        surfacePixel = texture(maskTex, clamp(maskUV, 0.001, 0.999));
        if (surfacePixel.a < maskAlphaThreshold) discard;
    }

    float cornerSdf = getCornerSDF(uv);

    if (cornerSdf > 0.0) {
        discard;
    }

    float cornerAlpha = 1.0 - smoothstep(-1.5, 0.5, cornerSdf);
    if (cornerAlpha < 0.001) discard;

    float minDim = min(fullSize.x, fullSize.y);
    float bezelWidthPx = edgeThickness * minDim;

    // ========================================
    // EDGE PROXIMITY + DIRECTION
    // edgeProximity: 1.0 at boundary, exponential decay inward
    // inwardDir: pixel-space direction toward center (smooth everywhere)
    // ========================================
    float edgeProximity = exp(cornerSdf / bezelWidthPx);
    vec2 inwardDir = refractionDir(uv);

    // ========================================
    // EDGE REFRACTION
    // Offset sampling UV inward (toward center) at edges — like looking
    // through the curved thick edge of a glass slab. This compresses
    // and distorts what's already behind the window, without reaching
    // beyond the window boundary.
    // ========================================
    float refractionPx = refractionStrength * 50.0;
    float refractionMag = edgeProximity * refractionPx;
    vec2 baseOffset = inwardDir * refractionMag / fullSize;

    // ========================================
    // CHROMATIC ABERRATION — per-channel refraction scale
    // Blue refracts more than red → natural spectral fringing at edges.
    // ========================================
    float chromaSpread = chromaticAberration * 0.35;
    vec2 offsetR = baseOffset * (1.0 - chromaSpread);
    vec2 offsetG = baseOffset;
    vec2 offsetB = baseOffset * (1.0 + chromaSpread);

    // ========================================
    // CENTER DOME LENS (subtle magnification in the flat interior)
    // Fades near edges so it doesn't interfere with edge refraction.
    // ========================================
    vec2 domeUV = vec2(0.0);
    if (lensDistortion > 0.001) {
        vec2 c = (uv - 0.5) * 2.0;
        vec2 dGrad = vec2(
            -4.0 * c.x * (1.0 - c.y * c.y),
            -4.0 * c.y * (1.0 - c.x * c.x)
        );
        float lensMaxPx = lensDistortion * minDim * 0.006;
        float lensFade = 1.0 - edgeProximity;
        domeUV = dGrad * lensMaxPx * lensFade / fullSize;
    }

    // ========================================
    // BACKGROUND SAMPLING (frosted blur only)
    // Nearby color influence comes naturally from the Gaussian blur
    // kernel crossing the window boundary — no explicit raw sampling.
    // ========================================
    vec3 color;
    vec2 uvR = uv + offsetR + domeUV;
    vec2 uvG = uv + offsetG + domeUV;
    vec2 uvB = uv + offsetB + domeUV;

    if (chromaticAberration > 0.001 && edgeProximity > 0.01) {
        color.r = sampleBlurred(uvR).r;
        color.g = sampleBlurred(uvG).g;
        color.b = sampleBlurred(uvB).b;
    } else {
        color = sampleBlurred(uvG).rgb;
    }

    // ========================================
    // FROSTED TINT (per-theme tone mapping)
    // ========================================
    float blurredLum = dot(color, vec3(0.2126, 0.7152, 0.0722));

    // Frosted desaturation
    color = mix(vec3(blurredLum), color, saturation);

    // Tight smoothstep range maps the blur-compressed luminance (~0.3-0.7)
    // to the full [0,1] adaptive range, creating visible per-region differentiation
    float lumCurve = smoothstep(0.25, 0.55, blurredLum);

    // Dim: multiplicative — effective at darkening bright areas
    color *= brightness * (1.0 - adaptiveDim * lumCurve);

    // Boost: additive lift — multiplicative can't brighten near-black content
    color += vec3(adaptiveBoost * (1.0 - lumCurve) * 0.5);

    // Contrast (pivot around midpoint)
    color = mix(vec3(0.5), color, contrast);

    // Vibrancy (selective saturation boost scaled by existing saturation)
    float currentLum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float sat = max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));
    float darkFactor = 1.0 - vibrancyDarkness * (1.0 - blurredLum);
    color = mix(vec3(currentLum), color, 1.0 + vibrancy * sat * darkFactor);

    // ========================================
    // COLOR TINT OVERLAY
    // ========================================
    color = mix(color, tintColor, tintAlpha);

    // ========================================
    // CAUSTIC SHIMMER — light through a moving surface
    //
    // Added after the tint and before the rim effects so the veins sit IN the
    // glass rather than on top of it, and so fresnel/specular still read as the
    // outermost layer.
    //
    // The brightening is tinted slightly warm and applied against the pixel's
    // own luminance: bright areas take less, so text underneath never gets
    // washed out. Scale is in window-widths rather than pixels, so a small
    // popup and a maximised window show the same size of wave rather than the
    // popup looking like a close-up.
    // ========================================
    if (shimmerIntensity > 0.001) {
        // Sample the water at the REFRACTED coordinate, not the raw one. The
        // glass bends what is behind it; the caustics live in that same water,
        // so they must bend with it. Using plain uv made the pattern ignore the
        // edge entirely and meet the border as a hard line.
        vec2 causticUV = uvG + domeUV;
        // Size-independent mapping, so a popup and a maximised window show the
        // same size of cell rather than one looking like a close-up.
        // Zoom about the CENTRE. Scaling the uv directly scales about (0,0),
        // i.e. the top-left corner, so changing wave size slid the whole pattern
        // toward that corner instead of growing in place.
        vec2 wp = (causticUV - 0.5) * (fullSize / max(fullSize.x, 1.0))
                * (0.85 * shimmerScale) + 0.5;
        float c = caustic(wp);

        if (shimmerLightFromBackdrop != 0) {
            // THE BACKDROP IS THE LIGHT SOURCE.
            // A caustic does not add light, it REDISTRIBUTES light that is
            // already there: the bright parts of whatever is behind the glass
            // get focused into the veins. So sample the backdrop again, pulled
            // along the wave slope, and weight it by the focus term. A dark
            // wallpaper therefore stays dark instead of growing white worms,
            // and a bright one lights its own caustics in its own colours.
            vec2 slope = waveSlope(wp, 0.0150);
            vec2 pull  = slope * (0.012 * shimmerScale);
            vec3 lit   = sampleBlurred(uv + pull).rgb;
            // Bias toward the brighter side of the backdrop: focused light comes
            // from the highlights, not the average.
            float lum  = dot(lit, vec3(0.2126, 0.7152, 0.0722));
            color += lit * c * shimmerIntensity * (0.35 + 1.15 * lum);
        } else {
            // Independent light: a plain warm source, for when the backdrop is
            // too dark to carry the effect (or a future explicit light).
            float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float headroom = 1.0 - smoothstep(0.55, 1.0, lum);
            color += vec3(1.0, 0.985, 0.95) * c * shimmerIntensity * 0.35 * headroom;
        }
    }

    // ========================================
    // FRESNEL RIM GLOW (edge zone)
    // ========================================
    if (fresnelStrength > 0.001) {
        float fresnel = edgeProximity * edgeProximity * fresnelStrength * 0.15;
        color += vec3(1.0) * fresnel;
    }

    // ========================================
    // SPECULAR — subtle top highlight (edge zone)
    // ========================================
    if (specularStrength > 0.001) {
        float topBias = pow(max(1.0 - uv.y, 0.0), 2.0);
        float spec = topBias * edgeProximity * edgeProximity * specularStrength * 0.08;
        color += vec3(1.0, 0.99, 0.97) * spec;
    }

    // ========================================
    // INNER SHADOW (bottom rim)
    // ========================================
    {
        float bottomBias = pow(uv.y, 2.0);
        float shadow = bottomBias * edgeProximity * edgeProximity * 0.06;
        color *= 1.0 - shadow;
    }

    float glassA = glassOpacity * cornerAlpha;

    if (hasMask) {
        // Layers only: composite the rendered surface over the glass effect
        // in a single pass. surfacePixel is premultiplied alpha from Hyprland's
        // surface rendering, so we unpremultiply before the 'over' blend.
        float surfA = surfacePixel.a;
        vec3 surfRGB = surfA > 0.001 ? surfacePixel.rgb / surfA : vec3(0.0);

        float compA = surfA + glassA * (1.0 - surfA);
        vec3 compRGB = compA > 0.001
            ? (surfRGB * surfA + color * glassA * (1.0 - surfA)) / compA
            : vec3(0.0);

        // Hyprland's compositor expects premultiplied alpha (blend GL_ONE, GL_ONE_MINUS_SRC_ALPHA).
        fragColor = vec4(compRGB * compA, compA);
    } else {
        // Windows: output the glass effect alone, surface is rendered separately by Hyprland.
        // Premultiplied: without this, a fading window's glass keeps full RGB contribution
        // because the GL_ONE source factor adds raw color regardless of alpha.
        fragColor = vec4(color * glassA, glassA);
    }
}
)GLSL"},

    {"wavesim.frag", R"GLSL(
#version 300 es
precision highp float;

/*
 * WAVE EQUATION STEP  —  d2h/dt2 = c^2 * laplacian(h) - damping
 *
 * WHY THIS EXISTS AT ALL:
 *   Every analytic surface tried before this (plane waves, radial sources,
 *   random-phase Gaussian spectra, multi-scale superposition) shares one fatal
 *   property: it is STATISTICALLY STATIONARY. The statistics are identical at
 *   every point and every moment, forever, so nothing is ever surprised — and
 *   human pattern recognition detects exactly that, no matter how the sum is
 *   dressed up. It is a structural limit of sums of oscillators, not a tuning
 *   problem, which is why six rounds of retuning all read as "patterned".
 *
 *   Integrating the actual wave equation is a different kind of object: a
 *   dynamical system with STATE. A disturbance starts somewhere, spreads at
 *   finite speed, reflects off boundaries, interferes with its own reflections,
 *   and dies out. What happens here now depends on what happened over there
 *   earlier. That history is the thing that cannot be faked with sines.
 *
 * ENCODING: R = h(t), G = h(t-1). Both are signed and stored biased by 0.5 so
 * an ordinary UNORM target can hold negative amplitudes.
 */

uniform sampler2D tex;        // previous state (R = h, G = h_prev)
uniform vec2  texelSize;
uniform float waveSpeed;      // (c*dt/dx)^2 — MUST stay < 0.5 or it explodes
uniform float damping;        // per-step energy retention, slightly below 1
uniform vec4  impulse;        // xy = position (uv), z = radius, w = strength
uniform float bedVariation;   // 0 = flat bottom, 1 = strongly uneven

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

// UNEVEN BOTTOM.
// Wave speed in shallow water is c = sqrt(g*h), so a varying depth refracts
// wavefronts: parts of a crest travelling over deeper water outrun parts over
// shallows, and a clean front gradually buckles on its own. Without this a
// wavefront stays a perfect arc until it happens to hit another wave, which is
// exactly the "static as it pans across" look.
//
// This is the RIGHT place to put irregularity: the bed is STATIC and only
// affects propagation speed, so it can never show up as a pattern in the
// caustics the way an irregular surface would. Three sin products, evaluated
// on the 512x512 sim grid only — not per screen pixel — so it is nearly free.
float bedDepth(vec2 p) {
    float d = sin(p.x * 7.3 + 1.7) * sin(p.y * 5.9 - 0.4)
            + 0.55 * sin(p.x * 13.1 - 2.2) * sin(p.y * 11.7 + 1.1)
            + 0.30 * sin((p.x + p.y) * 19.3 + 0.6);
    return d * 0.5;   // roughly -1..1
}

void main() {
    vec2 uv = v_texcoord;
    vec4 c  = texture(tex, uv);
    float h      = c.r - 0.5;
    float hPrev  = c.g - 0.5;

    // 5-point Laplacian. Sampling with clamped edges makes the boundary behave
    // like a wall, so waves REFLECT instead of vanishing — that reflection is a
    // large part of what makes a real pool look busy in a non-repeating way.
    float l = (texture(tex, uv + vec2(-texelSize.x, 0.0)).r - 0.5)
            + (texture(tex, uv + vec2( texelSize.x, 0.0)).r - 0.5)
            + (texture(tex, uv + vec2(0.0, -texelSize.y)).r - 0.5)
            + (texture(tex, uv + vec2(0.0,  texelSize.y)).r - 0.5)
            - 4.0 * h;

    // Explicit second-order integration: h(t+1) = 2h - h(t-1) + c^2 * lap
    // Local propagation speed from the local depth. Clamped well under the
    // Courant limit (0.5) at the FAST end, or the scheme diverges wherever the
    // water is deepest.
    float localSpeed = clamp(waveSpeed * (1.0 + bedVariation * bedDepth(uv)), 0.02, 0.48);

    float hNext = (2.0 * h - hPrev + localSpeed * l) * damping;

    // Occasional localized push — "someone moved at the far end of the pool".
    // Energy arrives later, from a direction, and then fades: the pacing the
    // constant-amplitude sine sum could never produce.
    if (impulse.w != 0.0) {
        float d = length((uv - impulse.xy) * vec2(1.0, texelSize.x / max(texelSize.y, 1e-6)));
        hNext += exp(-(d * d) / max(impulse.z * impulse.z, 1e-9)) * impulse.w;
    }

    hNext = clamp(hNext, -0.49, 0.49);
    fragColor = vec4(hNext + 0.5, h + 0.5, 0.0, 1.0);
}
)GLSL"},

    {"gaussianblur.frag", R"GLSL(
#version 300 es
precision highp float;

uniform sampler2D tex;
uniform vec2 direction; // (1.0/width, 0.0) for horizontal, (0.0, 1.0/height) for vertical
uniform float blurRadius; // kernel radius in pixels

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

void main() {
    // Compute sigma from radius (covers ~3 sigma)
    float sigma = max(blurRadius / 3.0, 0.001);
    float invSigma2 = -0.5 / (sigma * sigma);

    int samples = min(int(ceil(blurRadius)), 8);

    // Center tap
    float w0 = 1.0;
    vec4 result = texture(tex, v_texcoord) * w0;
    float totalWeight = w0;

    // Linear sampling: pair adjacent taps (i, i+1) into a single bilinear fetch.
    // The interpolated offset between two texels yields their weighted average
    // in one texture() call, halving the total tap count.
    for (int i = 1; i <= samples; i += 2) {
        float x1 = float(i);
        float x2 = float(i + 1);
        float w1 = exp(x1 * x1 * invSigma2);
        float w2 = (i + 1 <= samples) ? exp(x2 * x2 * invSigma2) : 0.0;
        float wSum = w1 + w2;
        if (wSum < 0.0001) continue;

        // Offset biased toward the heavier weight
        float offset = (x1 * w1 + x2 * w2) / wSum;

        result += texture(tex, v_texcoord + direction * offset) * wSum;
        result += texture(tex, v_texcoord - direction * offset) * wSum;
        totalWeight += 2.0 * wSum;
    }

    fragColor = result / totalWeight;
}
)GLSL"},
};
