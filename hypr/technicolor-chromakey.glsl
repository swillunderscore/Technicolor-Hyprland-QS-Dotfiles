// technicolor-chromakey.glsl — self-calibrating binary chroma key (v4).
//
// THE KEY IS SAMPLED FROM THE WINDOW'S TOP-LEFT PIXEL (always painted with the
// theme's background color) — no baked key uniform. The theme generator picks,
// per wallpaper, the key color farthest from the whole palette, so content
// never sits near the key (near-key palettes caused noisy speckled edges).
//
// Edges are BINARY: a pixel is either fully content or fully transparent
// (threshold on geometric-ish coverage). Semi-transparent edge bands reveal
// the compositor/glass underlay as rings — never emit partial alpha. Kept
// boundary pixels stay as rendered (no "recovery" math: the un-mix division
// amplified noise into dark speckles).
uniform float sim;   // key tolerance
uniform float choke; // coverage threshold: 0.5 neutral, higher bites inward

void windowShader(inout vec4 color) {
    // self-calibrated key: a point 0.2% in from the top-left corner (always
    // theme background; fixed texcoord — no window-size math, which produced
    // garbage keys and keyed the whole window away)
    vec3 key = texture(x_Tex, vec2(0.002, 0.002)).rgb;

    float dist = length(color.rgb - key);

    // pure key -> fully transparent
    // (min() keeps `choke` an active uniform — the plugin test-compiles with a
    // constant color, Mesa dead-codes the edge branch, and an inactive uniform
    // aborts loading)
    if (dist < sim + min(choke, 0.0)) {
        color = vec4(0.0);
        return;
    }

    // neighbor scan out to 4px: fade/feather bands on curved elements span
    // several pixels; the detection ring must reach past them
    float nearKey = 0.0;
    float bestD = dist;
    float dn;
    dn = length(texture(x_Tex, x_TexCoord + vec2( 1.25,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-1.25,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 ,  1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 , -1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 1.25,  1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-1.25, -1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 1.25, -1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-1.25,  1.25) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 2.5 ,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-2.5 ,  0.0 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 ,  2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 0.0 , -2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 2.5 ,  2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-2.5 , -2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2( 2.5 , -2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);
    dn = length(texture(x_Tex, x_TexCoord + vec2(-2.5 ,  2.5 ) / x_WindowSize).rgb - key); nearKey = max(nearKey, step(dn, sim)); bestD = max(bestD, dn);

    if (nearKey > 0.5) {
        float a = clamp(dist / max(bestD, 0.0001), 0.0, 1.0);
        if (a < clamp(choke, 0.05, 0.95)) {
            color = vec4(0.0);   // below threshold: gone
            return;
        }
        // POST-KEY ANTI-ALIASING: the chroma decision stays binary; the kept
        // edge is then feathered geometrically — alpha from the fraction of
        // immediate (1px) neighbors that are key-pure. No color recovery, no
        // key contamination: just sub-pixel coverage on the boundary row.
        float kc = 0.0;
        kc += step(length(texture(x_Tex, x_TexCoord + vec2( 1.0,  0.0) / x_WindowSize).rgb - key), sim);
        kc += step(length(texture(x_Tex, x_TexCoord + vec2(-1.0,  0.0) / x_WindowSize).rgb - key), sim);
        kc += step(length(texture(x_Tex, x_TexCoord + vec2( 0.0,  1.0) / x_WindowSize).rgb - key), sim);
        kc += step(length(texture(x_Tex, x_TexCoord + vec2( 0.0, -1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2( 1.0,  1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2(-1.0, -1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2( 1.0, -1.0) / x_WindowSize).rgb - key), sim);
        kc += 0.5 * step(length(texture(x_Tex, x_TexCoord + vec2(-1.0,  1.0) / x_WindowSize).rgb - key), sim);
        float aa = clamp(1.0 - kc / 6.0, 0.0, 1.0);
        color = vec4(color.rgb * aa, aa);   // premultiplied
    }
}
